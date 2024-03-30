const std = @import("std");

pub fn RateLimiter(comptime n_action: u32, comptime time_periode: u64) type {
    return struct {
        const Self = @This();

        comptime n_action: u32 = n_action,
        comptime time_periode: u64 = time_periode,

        tss: [n_action]std.time.Instant = [_]std.time.Instant{undefined} ** n_action,
        n_tss: usize = 0,

        pub fn push_action(self: *Self, instant: std.time.Instant) bool {
            if (self.n_tss == self.n_action) self.clear_out_of_periode(instant);
            if (self.n_tss == self.n_action) return false;
            self.tss[self.n_tss] = instant;
            self.n_tss += 1;
            return true;
        }

        pub fn wait_to_clear(self: *Self, instant: std.time.Instant) void {
            const time_to_wait = time_periode - instant.since(self.last_tss());
            std.time.sleep(time_to_wait);
            self.n_tss = 0;
        }

        pub fn clear_out_of_periode(self: *Self, instant: std.time.Instant) void {
            var i: usize = 0;
            var oldest = self.tss[i];
            while (instant.since(oldest) > self.time_periode) {
                self.n_tss -= 1;
                if (self.n_tss == 0) break;
                i += 1;
                oldest = self.tss[i];
            } else {
                std.mem.rotate(std.time.Instant, &self.tss, i);
            }
        }

        fn last_tss(self: Self) std.time.Instant {
            return self.tss[self.n_tss - 1];
        }
    };
}
