const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;

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

        const max_count = @as(u64, @bitCast(@as(i64, -1)));
        if (current >= previous) {
            return @as(f64, @floatFromInt(current - previous)) / interval;
        } else {
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
        var it = self.prev_traffic.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
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

    fn getInterfaceState(interface: []const u8) []const u8 {
        var path_buf: [256]u8 = undefined;
        const path = fmt.bufPrint(&path_buf, "/sys/class/net/{s}/operstate", .{interface}) catch return "unknown";
        
        const file = fs.openFileAbsolute(path, .{}) catch return "unknown";
        defer file.close();
        
        var buf: [16]u8 = undefined;
        const bytes = file.read(&buf) catch return "unknown";
        return mem.trim(u8, buf[0..bytes], " \n");
    }

    fn getDivisor(self: *NetworkMonitor) u64 {
        return if (mem.eql(u8, self.config.units, "decimal")) 1000 else 1024;
    }

    fn getUnits(self: *NetworkMonitor) []const []const u8 {
        const binary_units = &[_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
        const decimal_units = &[_][]const u8{ "B", "KB", "MB", "GB", "TB" };
        return if (mem.eql(u8, self.config.units, "decimal")) decimal_units else binary_units;
    }

    fn formatBytes(self: *NetworkMonitor, arena: std.mem.Allocator, size: u64) ![]const u8 {
        if (size == 0) return arena.dupe(u8, "0B");

        const divisor = self.getDivisor();
        const units = self.getUnits();
        var unit_idx: usize = 0;
        var readable: f64 = @as(f64, @floatFromInt(size));

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
            
        return arena.dupe(u8, result);
    }

    fn formatRatePrecise(self: *NetworkMonitor, arena: std.mem.Allocator, bytes_per_sec: f64) ![]const u8 {
        if (bytes_per_sec <= 0) return arena.dupe(u8, "0B/s");

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
            
        return arena.dupe(u8, result);
    }

    fn parseProcNetDev(self: *NetworkMonitor, arena: std.mem.Allocator) !std.StringHashMap(InterfaceTraffic) {
        var stats = std.StringHashMap(InterfaceTraffic).init(arena);
        errdefer {
            var it = stats.keyIterator();
            while (it.next()) |key| {
                arena.free(key.*);
            }
            stats.deinit();
        }

        const file = fs.openFileAbsolute(PROC_NET_DEV, .{}) catch return stats;
        defer file.close();

        var content: [8192]u8 = undefined;
        const bytes_read = try file.readAll(&content);
        const content_slice = content[0..bytes_read];
        
        var line_num: usize = 0;
        var line_iter = mem.tokenizeScalar(u8, content_slice, '\n');
        
        while (line_iter.next()) |line| {
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
                traffic.state = NetworkMonitor.getInterfaceState(iface);
                const iface_copy = try arena.dupe(u8, iface);
                try stats.put(iface_copy, traffic);
            }

            if (stats.count() >= self.config.max_interfaces) break;
        }

        return stats;
    }
};

fn clearScreen() void {
    std.debug.print("\x1b[H\x1b[J", .{});
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
        var it = prev_stats.keyIterator();
        while (it.next()) |key| {
            monitor.allocator.free(key.*);
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

        var arena = std.heap.ArenaAllocator.init(monitor.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        var curr_stats = monitor.parseProcNetDev(temp_allocator) catch |err| {
            std.debug.print("{s}Error reading network stats: {s}{s}\n", .{ Colors.RED, @errorName(err), Colors.RESET });
            const sleep_duration = @as(u64, @intFromFloat(interval * 1_000_000_000));
            std.Thread.sleep(sleep_duration);
            continue;
        };

        var iface_list = std.ArrayList(InterfaceEntry){};
        try iface_list.ensureTotalCapacity(temp_allocator, 20);
        
        var it = curr_stats.iterator();
        while (it.next()) |entry| {
            const iface = entry.key_ptr.*;
            const now = entry.value_ptr.*;
            try iface_list.append(temp_allocator, .{ .name = iface, .traffic = now });
        }

        const items = iface_list.items;
        std.sort.block(InterfaceEntry, items, {}, struct {
            fn lessThan(_: void, a: InterfaceEntry, b: InterfaceEntry) bool {
                return a.traffic.totalBytes() > b.traffic.totalBytes();
            }
        }.lessThan);

        var line_buf: [256]u8 = undefined;
        for (items) |item| {
            const iface = item.name;
            const now = item.traffic;
            const state_color = if (now.isUp()) Colors.GREEN else Colors.RED;

            var stream = std.io.fixedBufferStream(&line_buf);
            var writer = stream.writer();

            try writer.print("{s}{s:<12}{s} [{s}{s:<5}{s}]", .{
                Colors.SEPIA, iface, Colors.RESET, state_color, now.state, Colors.RESET,
            });

            if (prev_stats.get(iface)) |prev| {
                const rx_rate = RateCalculator.calculateRate(now.rx_bytes, prev.rx_bytes, interval);
                const tx_rate = RateCalculator.calculateRate(now.tx_bytes, prev.tx_bytes, interval);

                const rx_str = try monitor.formatRatePrecise(temp_allocator, rx_rate);
                const tx_str = try monitor.formatRatePrecise(temp_allocator, tx_rate);

                try writer.print(" RX: {s}{s:<12}{s}", .{ Colors.GREEN, rx_str, Colors.RESET });
                try writer.print(" TX: {s}{s:<12}{s}", .{ Colors.YELLOW, tx_str, Colors.RESET });
            } else {
                const rx_str = try monitor.formatBytes(temp_allocator, now.rx_bytes);
                const tx_str = try monitor.formatBytes(temp_allocator, now.tx_bytes);

                try writer.print(" RX: {s}{s:<12}{s}", .{ Colors.GREEN, rx_str, Colors.RESET });
                try writer.print(" TX: {s}{s:<12}{s}", .{ Colors.YELLOW, tx_str, Colors.RESET });
                try writer.print(" {s}(cumulative){s}", .{ Colors.GREY, Colors.RESET });
            }

            std.debug.print("{s}\n", .{line_buf[0..stream.pos]});
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

        const total_rx_str = try monitor.formatBytes(temp_allocator, total_rx);
        const total_tx_str = try monitor.formatBytes(temp_allocator, total_tx);

        const now_timestamp = std.time.timestamp();
        const hours = @mod(@divTrunc(now_timestamp, 3600), 24);
        const minutes = @mod(@divTrunc(now_timestamp, 60), 60);
        const seconds = @mod(now_timestamp, 60);
        var time_buf: [9]u8 = undefined;
        const time_str = try fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });

        std.debug.print("\n{s}[Ctrl+C to stop] | Interfaces: {d} (active: {d}) | Total: RX {s} / TX {s} | Time: {s}{s}\n", .{
            Colors.GREY, curr_stats.count(), active_count,
            total_rx_str, total_tx_str, time_str, Colors.RESET,
        });

        var prev_it = prev_stats.keyIterator();
        while (prev_it.next()) |key| {
            monitor.allocator.free(key.*);
        }
        prev_stats.clearAndFree();

        var curr_it = curr_stats.iterator();
        while (curr_it.next()) |entry| {
            const iface_copy = try monitor.allocator.dupe(u8, entry.key_ptr.*);
            try prev_stats.put(iface_copy, entry.value_ptr.*);
        }

        update_count += 1;

        const sleep_duration = @as(u64, @intFromFloat(interval * 1_000_000_000));
        std.Thread.sleep(sleep_duration);
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
