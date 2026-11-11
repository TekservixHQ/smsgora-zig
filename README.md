# smsgora (Zig)

[![tests](https://github.com/TekservixHQ/smsgora-zig/actions/workflows/tests.yml/badge.svg)](https://github.com/TekservixHQ/smsgora-zig/actions/workflows/tests.yml)

Zig client for the [SMS Gora SMS Gateway](https://tekservix.com/smsgora/) API.

SMS Gora turns Android phones with ordinary SIM cards into an SMS gateway. Your code calls the API, a linked phone sends the text, and replies and delivery reports come back to you. There's no sender ID registration and no per-message fee from us.

Zig 0.15.1+, standard library only (std.http, std.json, std.crypto).

## Install

```bash
zig fetch --save git+https://github.com/TekservixHQ/smsgora-zig#v1.0.0
```

Then in `build.zig`:

```zig
const smsgora = b.dependency("smsgora", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("smsgora", smsgora.module("smsgora"));
```

## Usage

You need a Tekservix account with SMS Gora and an API key (SMS Gora → API keys). Keep it on your server.

```zig
const std = @import("std");
const smsgora = @import("smsgora");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const api_key = std.posix.getenv("SMSGORA_KEY") orelse return error.MissingKey;

    var c = try smsgora.Client.init(gpa, api_key, .{});
    defer c.deinit();

    const res = c.sendSms(&.{"+15551234567"}, "Your code is 482913", .{}) catch |err| {
        if (err == error.ApiError) std.debug.print("SMS Gora: {s} (HTTP {d})\n", .{ c.last_error.message, c.last_error.status });
        return err;
    };
    defer res.deinit();
    // res.data() is {"message_ids": [...]}

    // From a chosen phone and SIM, scheduled for later
    (try c.sendSms(&.{ "+15551234567", "+447700900123" }, "Reminder: 10:00", .{ .device_id = "42", .sim_slot = 1, .schedule_at = "2026-12-01T08:00:00Z" })).deinit();

    // Status, inbox, phones, account, or any other endpoint
    (try c.getMessage("1873")).deinit();
    (try c.listReceivedSms(null)).deinit();
    (try c.request(.GET, "/batches/311", null)).deinit();
}
```

Every call returns a `Result` (call `deinit()`), or `error.ApiError` with details in `client.last_error`. The HTTP transport can be replaced (`.transport` option) for tests or proxies.

Webhooks carry `X-SmsGora-Signature: sha256=...` (HMAC-SHA256 of the raw body): check it with `smsgora.verifyWebhook(raw_body, signature, secret)`.

## More from Tekservix

- [WAservix WhatsApp API Gateway](https://tekservix.com/waservix/) ([Zig client](https://github.com/TekservixHQ/waservix-zig))
- [AI Sales Agent](https://tekservix.com/ai-sales-agent) and [Website to App](https://tekservix.com/mobile-apps)
- Libraries for many more languages: [github.com/TekservixHQ](https://github.com/TekservixHQ)

## License

MIT
