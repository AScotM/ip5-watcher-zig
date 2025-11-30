const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const time = std.time;
const Thread = std.Thread;
const sort = std.sort;

const PROC_NET_DEV = "/proc/net/dev";
const SYSFS_NET_PATH = "/sys/class/net";

const Colors = struct {
    const RESET = "\x1b[0m";
    const GREY = "\x1b[38;5;250m";
    const SEPIA = "\x1b[38;5;130m";
    const RED = "\x1b[31m";
    const GREEN = "\x1b[32m";
    const YELLOW = "\x1b[33m";
    const BLUE = "\x1b[34m";
    const CYAN = "\x1b[36m";
    const MAGENTA = "\x1b[35m";

    var disabled: bool = false;

    fn disable() void {
        disabled = true;
    }

    fn color(comptime code: []const u8) []const u8 {
        if (disabled) return "";
        return code;
    }
};

const MonitorConfig = struct {
    interval: f64 = 1.0,
    max_interfaces: usize = 100,
    show_loopback: bool = true,
    show_inactive: bool = false,
    precision: usize = 1,
    units: []const u8 = "binary",
};

const InterfaceTraffic = struct {
    name: []const u8,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_packets: u64 = 0,
    tx_packets: u64 = 0,
    rx_errs: u64 = 0,
    tx_errs: u64 = 0,
    rx_drop: u64 = 0,
    tx_drop: u64 = 0,
    state: []const u8 = "unknown",

    fn isActive(self: *const InterfaceTraffic) bool {
        return self.rx_bytes > 0 or self.tx_bytes > 0 or self.rx_packets > 0 or self.tx_packets > 0;
    }

    fn isUp(self: *const InterfaceTraffic) bool {
        return mem.eql(u8, self.state, "up");
    }

    fn totalBytes(self: *const InterfaceTraffic) u64 {
        return self.rx_bytes + self.tx_bytes;
    }

    fn totalPackets(self: *const InterfaceTraffic) u64 {
        return self.rx_packets + self.tx_packets;
    }
};

const RateCalculator = struct {
    fn calculateRate(current: u64, previous: u64, interval: f64) f64 {
        if (interval <= 0) return 0.0;

        if (current >= previous) {
            return @as(f64, @floatFromInt(current - previous)) / interval;
        } else {
            // Handle counter wrap-around
            const max_count = (@as(u64, 1) << 32) - 1;
            return @as(f64, @floatFromInt((max_count - previous) + current + 1)) / interval;
        }
    }
};

const NetworkMonitor = struct {
    config: MonitorConfig,
    allocator: mem.Allocator,
    prev_traffic: std.StringHashMap(InterfaceTraffic),

    fn init(allocator: mem.Allocator, config: MonitorConfig) NetworkMonitor {
        return .{
            .config = config,
            .allocator = allocator,
            .prev_traffic = std.StringHashMap(InterfaceTraffic).init(allocator),
        };
    }

    fn deinit(self: *NetworkMonitor) void {
        var it = self.prev_traffic.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.prev_traffic.deinit();
    }

    fn safeInterfaceName(name: []const u8) bool {
        if (name.len == 0 or name.len > 64) return false;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') {
                return false;
            }
        }
        return true;
    }

    fn getInterfaceState(_: *NetworkMonitor, interface: []const u8) []const u8 {
        // Simple state detection - assume most interfaces are up for basic functionality
        // You can enhance this later with proper sysfs reading
        if (mem.eql(u8, interface, "lo")) return "up"; // loopback is always up
        return "up"; // Assume up for now to avoid sysfs issues
    }

    fn getAvailableInterfaces(self: *NetworkMonitor) !std.ArrayList([]const u8) {
        var interfaces = std.ArrayList([]const u8).init(self.allocator);
        errdefer interfaces.deinit();

        var dir = fs.openDirAbsolute(SYSFS_NET_PATH, .{ .iterate = true }) catch return interfaces;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!NetworkMonitor.safeInterfaceName(entry.name)) continue;

            if (!self.config.show_loopback and mem.eql(u8, entry.name, "lo")) continue;

            const iface = try self.allocator.dupe(u8, entry.name);
            try interfaces.append(iface);
        }

        return interfaces;
    }

    fn getDivisor(self: *NetworkMonitor) u64 {
        return if (mem.eql(u8, self.config.units, "decimal")) 1000 else 1024;
    }

    fn getUnits(self: *NetworkMonitor) []const []const u8 {
        const binary_units = &[_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
        const decimal_units = &[_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        return if (mem.eql(u8, self.config.units, "decimal")) decimal_units else binary_units;
    }

    fn formatBytes(self: *NetworkMonitor, size: u64) ![]const u8 {
        if (size == 0) return self.allocator.dupe(u8, "0B");

        const divisor = self.getDivisor();
        const units = self.getUnits();
        var unit_idx: usize = 0;
        var readable: f64 = @floatFromInt(size);

        while (readable >= @as(f64, @floatFromInt(divisor)) and unit_idx < units.len - 1) {
            readable /= @as(f64, @floatFromInt(divisor));
            unit_idx += 1;
        }

        var buf: [32]u8 = undefined;
        const result = if (unit_idx == 0) 
            try fmt.bufPrint(&buf, "{d}{s}", .{ @as(u64, @intFromFloat(readable)), units[unit_idx] })
        else if (readable < 10)
            try fmt.bufPrint(&buf, "{d:.1}{s}", .{ readable, units[unit_idx] })
        else
            try fmt.bufPrint(&buf, "{d:.0}{s}", .{ readable, units[unit_idx] });
            
        return self.allocator.dupe(u8, result);
    }

    fn formatRatePrecise(self: *NetworkMonitor, bytes_per_sec: f64) ![]const u8 {
        if (bytes_per_sec <= 0) return self.allocator.dupe(u8, "0B/s");

        const divisor = self.getDivisor();
        const units = self.getUnits();
        var unit_idx: usize = 0;
        var readable = bytes_per_sec;

        while (readable >= @as(f64, @floatFromInt(divisor)) and unit_idx < units.len - 1) {
            readable /= @as(f64, @floatFromInt(divisor));
            unit_idx += 1;
        }

        var buf: [32]u8 = undefined;
        const result = if (unit_idx == 0)
            try fmt.bufPrint(&buf, "{d:.0}{s}/s", .{ readable, units[unit_idx] })
        else if (readable < 10)
            try fmt.bufPrint(&buf, "{d:.1}{s}/s", .{ readable, units[unit_idx] })
        else
            try fmt.bufPrint(&buf, "{d:.0}{s}/s", .{ readable, units[unit_idx] });
            
        return self.allocator.dupe(u8, result);
    }

    fn parseProcNetDev(self: *NetworkMonitor) !std.StringHashMap(InterfaceTraffic) {
        var stats = std.StringHashMap(InterfaceTraffic).init(self.allocator);
        errdefer {
            var it = stats.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            stats.deinit();
        }

        const file = fs.openFileAbsolute(PROC_NET_DEV, .{}) catch return stats;
        defer file.close();

        var reader = file.reader();
        var line_buf: [1024]u8 = undefined;
        var line_num: usize = 0;

        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            line_num += 1;
            if (line_num <= 2) continue;

            var parts = mem.tokenizeAny(u8, line, " \t");
            var field_num: usize = 0;
            var iface: []const u8 = undefined;
            var traffic = InterfaceTraffic{ .name = undefined };

            while (parts.next()) |part| {
                if (field_num == 0) {
                    iface = mem.trim(u8, part, ":");
                    traffic.name = iface;
                } else {
                    const value = fmt.parseInt(u64, part, 10) catch continue;
                    switch (field_num) {
                        1 => traffic.rx_bytes = value,
                        2 => traffic.rx_packets = value,
                        3 => traffic.rx_errs = value,
                        4 => traffic.rx_drop = value,
                        9 => traffic.tx_bytes = value,
                        10 => traffic.tx_packets = value,
                        11 => traffic.tx_errs = value,
                        12 => traffic.tx_drop = value,
                        else => {},
                    }
                }
                field_num += 1;
            }

            if (field_num >= 13) {
                // Get state using simple detection
                traffic.state = self.getInterfaceState(iface);

                const iface_copy = try self.allocator.dupe(u8, iface);
                try stats.put(iface_copy, traffic);
            }

            if (stats.count() >= self.config.max_interfaces) break;
        }

        return stats;
    }
};

fn clearScreen() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll("\x1b[H\x1b[J") catch {};
}

const InterfaceEntry = struct {
    name: []const u8,
    traffic: InterfaceTraffic,
};

fn watchMode(monitor: *NetworkMonitor, interval: f64) !void {
    if (interval < 0.01) {
        std.debug.print("{s}Interval too small: {d}s{s}\n", .{ Colors.RED, interval, Colors.RESET });
        return;
    }

    var prev_stats = std.StringHashMap(InterfaceTraffic).init(monitor.allocator);
    defer {
        var it = prev_stats.iterator();
        while (it.next()) |entry| {
            monitor.allocator.free(entry.key_ptr.*);
        }
        prev_stats.deinit();
    }

    const start_time = std.time.timestamp();
    var update_count: usize = 0;

    while (true) {
        clearScreen();
        const current_time = std.time.timestamp();
        const elapsed_total = @as(f64, @floatFromInt(current_time - start_time));

        std.debug.print("{s}Live Network Traffic Monitor{s}\n", .{ Colors.BLUE, Colors.RESET });
        std.debug.print("{s}Interval: {d}s | Uptime: {d:.0}s | Updates: {d}{s}\n\n", .{
            Colors.GREY, interval, elapsed_total, update_count, Colors.RESET,
        });

        var curr_stats = monitor.parseProcNetDev() catch |err| {
            std.debug.print("{s}Error reading network stats: {s}{s}\n", .{ Colors.RED, @errorName(err), Colors.RESET });
            // Sleep and continue instead of exiting
            const sleep_duration = @as(u64, @intFromFloat(interval * 1_000_000_000));
            std.time.sleep(sleep_duration);
            continue;
        };
        defer {
            var it = curr_stats.iterator();
            while (it.next()) |entry| {
                monitor.allocator.free(entry.key_ptr.*);
            }
            curr_stats.deinit();
        }

        var iface_list = std.ArrayList(InterfaceEntry).init(monitor.allocator);
        defer iface_list.deinit();

        var it = curr_stats.iterator();
        while (it.next()) |entry| {
            const iface = entry.key_ptr.*;
            const now = entry.value_ptr.*;
            try iface_list.append(.{ .name = iface, .traffic = now });
        }

        // Sort by total bytes
        sort.block(InterfaceEntry, iface_list.items, {}, struct {
            fn lessThan(_: void, a: InterfaceEntry, b: InterfaceEntry) bool {
                return a.traffic.totalBytes() > b.traffic.totalBytes();
            }
        }.lessThan);

        for (iface_list.items) |item| {
            const iface = item.name;
            const now = item.traffic;
            const state_color = if (now.isUp()) Colors.GREEN else Colors.RED;

            var line_parts = std.ArrayList([]const u8).init(monitor.allocator);
            defer {
                for (line_parts.items) |part| {
                    monitor.allocator.free(part);
                }
                line_parts.deinit();
            }

            try line_parts.append(try fmt.allocPrint(monitor.allocator, "{s}{s:<12}{s} [{s}{s:<5}{s}]", .{
                Colors.SEPIA, iface, Colors.RESET, state_color, now.state, Colors.RESET,
            }));

            if (prev_stats.get(iface)) |prev| {
                const rx_rate = RateCalculator.calculateRate(now.rx_bytes, prev.rx_bytes, interval);
                const tx_rate = RateCalculator.calculateRate(now.tx_bytes, prev.tx_bytes, interval);

                const rx_str = try monitor.formatRatePrecise(rx_rate);
                defer monitor.allocator.free(rx_str);
                const tx_str = try monitor.formatRatePrecise(tx_rate);
                defer monitor.allocator.free(tx_str);

                try line_parts.append(try fmt.allocPrint(monitor.allocator, "RX: {s}{s:<12}{s}", .{
                    Colors.GREEN, rx_str, Colors.RESET,
                }));

                try line_parts.append(try fmt.allocPrint(monitor.allocator, "TX: {s}{s:<12}{s}", .{
                    Colors.YELLOW, tx_str, Colors.RESET,
                }));
            } else {
                // First reading - show cumulative stats instead of rates
                const rx_str = try monitor.formatBytes(now.rx_bytes);
                defer monitor.allocator.free(rx_str);
                const tx_str = try monitor.formatBytes(now.tx_bytes);
                defer monitor.allocator.free(tx_str);

                try line_parts.append(try fmt.allocPrint(monitor.allocator, "RX: {s}{s:<12}{s}", .{
                    Colors.GREEN, rx_str, Colors.RESET,
                }));

                try line_parts.append(try fmt.allocPrint(monitor.allocator, "TX: {s}{s:<12}{s}", .{
                    Colors.YELLOW, tx_str, Colors.RESET,
                }));

                try line_parts.append(try fmt.allocPrint(monitor.allocator, "{s}(cumulative){s}", .{
                    Colors.GREY, Colors.RESET,
                }));
            }

            const line = try mem.join(monitor.allocator, " ", line_parts.items);
            defer monitor.allocator.free(line);
            std.debug.print("{s}\n", .{line});
        }

        if (curr_stats.count() == 0) {
            std.debug.print("{s}No active interfaces to monitor.{s}\n", .{ Colors.GREY, Colors.RESET });
        }

        var active_count: usize = 0;
        var total_rx: u64 = 0;
        var total_tx: u64 = 0;

        var stats_it = curr_stats.iterator();
        while (stats_it.next()) |entry| {
            const traffic = entry.value_ptr.*;
            if (traffic.isActive()) active_count += 1;
            total_rx += traffic.rx_bytes;
            total_tx += traffic.tx_bytes;
        }

        const total_rx_str = try monitor.formatBytes(total_rx);
        defer monitor.allocator.free(total_rx_str);
        const total_tx_str = try monitor.formatBytes(total_tx);
        defer monitor.allocator.free(total_tx_str);

        std.debug.print("\n{s}[Ctrl+C to stop] | Interfaces: {d} (active: {d}) | Total: RX {s} / TX {s}{s}\n", .{
            Colors.GREY, curr_stats.count(), active_count,
            total_rx_str, total_tx_str, Colors.RESET,
        });

        // Update previous stats for next iteration
        var prev_it = prev_stats.iterator();
        while (prev_it.next()) |entry| {
            monitor.allocator.free(entry.key_ptr.*);
        }
        prev_stats.clearAndFree();

        var curr_it = curr_stats.iterator();
        while (curr_it.next()) |entry| {
            const iface_copy = try monitor.allocator.dupe(u8, entry.key_ptr.*);
            try prev_stats.put(iface_copy, entry.value_ptr.*);
        }

        update_count += 1;

        const sleep_duration = @as(u64, @intFromFloat(interval * 1_000_000_000));
        std.time.sleep(sleep_duration);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = MonitorConfig{
        .interval = 1.0,
        .show_loopback = true,
        .show_inactive = false,
        .units = "binary",
        .precision = 1,
    };

    var monitor = NetworkMonitor.init(allocator, config);
    defer monitor.deinit();

    watchMode(&monitor, config.interval) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
    };
}
