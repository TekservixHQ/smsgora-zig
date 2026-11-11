//! Zig client for the SMS Gora SMS Gateway API (https://tekservix.com/smsgora/).
//!
//! SMS Gora turns Android phones with ordinary SIM cards into an SMS gateway: your server
//! calls the API, a linked phone sends the text, and replies and delivery reports come back.
//! Needs a Tekservix account with SMS Gora and an API key. Keep it on your server.

const std = @import("std");

pub const version = "1.0.0";
pub const default_base_url = "https://tekservix.com/smsgora/api/v1";

pub const Header = struct { name: []const u8, value: []const u8 };

/// What a transport returns. `body` is owned by the caller (allocated with the given allocator).
pub const HttpResponse = struct { status: u16, body: []u8 };

/// Sends one HTTP request. Replace it for tests, proxies or custom TLS.
pub const Transport = struct {
    ctx: ?*anyopaque = null,
    send: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse,
};

/// Details of the last API error (set when a call returns `error.ApiError`).
pub const ApiError = struct {
    /// HTTP status (0 when the request never reached the API).
    status: u16 = 0,
    /// Message from the API, or "HTTP <status>". Owned by the client.
    message: []const u8 = "",
};

/// A decoded answer. `data()` is the API's `data` field. Call `deinit()` when done.
pub const Result = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn data(self: Result) std.json.Value {
        if (self.parsed.value == .object) {
            if (self.parsed.value.object.get("data")) |d| return d;
        }
        return self.parsed.value;
    }

    pub fn deinit(self: Result) void {
        self.parsed.deinit();
    }
};

pub const Options = struct {
    base_url: []const u8 = default_base_url,
    transport: ?Transport = null,
};

pub const SendOptions = struct {
    /// Send from this phone (ID shown in the dashboard) instead of your best online one.
    device_id: ?[]const u8 = null,
    /// 0 = SIM 1, 1 = SIM 2.
    sim_slot: ?u8 = null,
    /// Send later: ISO 8601, e.g. "2026-12-01T08:00:00Z".
    schedule_at: ?[]const u8 = null,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    transport: Transport,
    last_error: ApiError = .{},
    message_buf: ?[]u8 = null,

    /// Create a client with your API key (starts with `sgk_`, from SMS Gora -> API keys).
    pub fn init(gpa: std.mem.Allocator, api_key: []const u8, opts: Options) !Client {
        if (api_key.len == 0) return error.MissingApiKey;
        return .{
            .gpa = gpa,
            .api_key = api_key,
            .base_url = std.mem.trimRight(u8, opts.base_url, "/"),
            .transport = opts.transport orelse .{ .send = httpSend },
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.message_buf) |m| self.gpa.free(m);
        self.message_buf = null;
    }

    fn setError(self: *Client, status: u16, message: []const u8) !void {
        if (self.message_buf) |m| self.gpa.free(m);
        self.message_buf = try self.gpa.dupe(u8, message);
        self.last_error = .{ .status = status, .message = self.message_buf.? };
    }

    /// Call any documented endpoint, e.g. `client.request(.GET, "/devices", null)`.
    /// On failure returns `error.ApiError` and fills `client.last_error`.
    pub fn request(self: *Client, method: std.http.Method, path: []const u8, body: ?[]const u8) !Result {
        const url = try std.mem.concat(self.gpa, u8, &.{ self.base_url, path });
        defer self.gpa.free(url);
        var headers_buf: [4]Header = undefined;
        var n: usize = 0;
        headers_buf[n] = .{ .name = "x-api-key", .value = self.api_key };
        n += 1;
        headers_buf[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        headers_buf[n] = .{ .name = "User-Agent", .value = "smsgora-zig/" ++ version };
        n += 1;
        if (body != null) {
            headers_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
            n += 1;
        }

        const res = self.transport.send(self.transport.ctx, self.gpa, method, url, headers_buf[0..n], body) catch |err| {
            try self.setError(0, @errorName(err));
            return error.ApiError;
        };
        defer self.gpa.free(res.body);

        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, if (res.body.len == 0) "null" else res.body, .{}) catch {
            if (res.status >= 400) {
                var buf: [32]u8 = undefined;
                try self.setError(res.status, try std.fmt.bufPrint(&buf, "HTTP {d}", .{res.status}));
                return error.ApiError;
            }
            return error.InvalidResponse;
        };
        var failed = res.status >= 400;
        var message: ?[]const u8 = null;
        if (parsed.value == .object) {
            if (parsed.value.object.get("success")) |s| {
                if (s == .bool and !s.bool) failed = true;
            }
            if (parsed.value.object.get("message")) |m| {
                if (m == .string) message = m.string;
            }
        }
        if (failed) {
            defer parsed.deinit();
            if (message) |m| {
                try self.setError(res.status, m);
            } else {
                var buf: [32]u8 = undefined;
                try self.setError(res.status, try std.fmt.bufPrint(&buf, "HTTP {d}", .{res.status}));
            }
            return error.ApiError;
        }
        return .{ .parsed = parsed };
    }

    /// Send an SMS to up to 1,000 numbers. `data()` is `{"message_ids": [...]}`.
    pub fn sendSms(self: *Client, to: []const []const u8, message: []const u8, opts: SendOptions) !Result {
        if (to.len == 0) return error.NoRecipients;
        const body = try std.json.Stringify.valueAlloc(self.gpa, .{
            .recipients = to,
            .message = message,
            .sim_slot = opts.sim_slot,
            .schedule_at = opts.schedule_at,
        }, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(body);
        if (opts.device_id) |d| {
            const path = try std.fmt.allocPrint(self.gpa, "/devices/{s}/send-sms", .{d});
            defer self.gpa.free(path);
            return self.request(.POST, path, body);
        }
        return self.request(.POST, "/send-sms", body);
    }

    /// Delivery status: queued, dispatched, sent, delivered, failed or cancelled.
    pub fn getMessage(self: *Client, id: []const u8) !Result {
        const path = try std.fmt.allocPrint(self.gpa, "/messages/{s}", .{id});
        defer self.gpa.free(path);
        return self.request(.GET, path, null);
    }

    /// Cancel a queued or scheduled message.
    pub fn cancelMessage(self: *Client, id: []const u8) !Result {
        const path = try std.fmt.allocPrint(self.gpa, "/messages/{s}/cancel", .{id});
        defer self.gpa.free(path);
        return self.request(.POST, path, null);
    }

    /// Incoming SMS for all phones, or one phone with `device_id`.
    pub fn listReceivedSms(self: *Client, device_id: ?[]const u8) !Result {
        if (device_id) |d| {
            const path = try std.fmt.allocPrint(self.gpa, "/devices/{s}/get-received-sms", .{d});
            defer self.gpa.free(path);
            return self.request(.GET, path, null);
        }
        return self.request(.GET, "/received-sms", null);
    }

    /// Your linked Android phones.
    pub fn listDevices(self: *Client) !Result {
        return self.request(.GET, "/devices", null);
    }

    /// Account, plan and usage.
    pub fn getAccount(self: *Client) !Result {
        return self.request(.GET, "/account", null);
    }

    /// Register a webhook for incoming SMS. The answer includes the secret (returned once).
    pub fn createWebhook(self: *Client, url: []const u8, events: []const []const u8) !Result {
        const body = try std.json.Stringify.valueAlloc(self.gpa, .{ .url = url, .events = events }, .{});
        defer self.gpa.free(body);
        return self.request(.POST, "/webhooks", body);
    }

    pub fn deleteWebhook(self: *Client, id: []const u8) !Result {
        const path = try std.fmt.allocPrint(self.gpa, "/webhooks/{s}", .{id});
        defer self.gpa.free(path);
        return self.request(.DELETE, path, null);
    }
};

/// Check the `X-SmsGora-Signature` header (`sha256=<hex HMAC-SHA256 of the raw body>`) in constant time.
pub fn verifyWebhook(raw_body: []const u8, signature: []const u8, secret: []const u8) bool {
    if (raw_body.len == 0 or signature.len == 0 or secret.len == 0) return false;
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, raw_body, secret);
    const hex = std.fmt.bytesToHex(mac, .lower);
    const expected = "sha256=" ++ hex;
    if (signature.len != expected.len) return false;
    var diff: u8 = 0;
    for (expected, signature) |a, b| diff |= a ^ b;
    return diff == 0;
}

fn httpSend(_: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse {
    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();
    const extra = try gpa.alloc(std.http.Header, headers.len);
    defer gpa.free(extra);
    for (headers, 0..) |h, i| extra[i] = .{ .name = h.name, .value = h.value };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = extra,
        .response_writer = &out.writer,
    });
    return .{ .status = @intFromEnum(res.status), .body = try out.toOwnedSlice() };
}

// ------------------------------------------------------------------------------- tests

const Fake = struct {
    status: u16 = 200,
    reply: []const u8 = "{\"success\":true,\"data\":{\"message_ids\":[1873]}}",
    method: std.http.Method = .GET,
    url: [256]u8 = undefined,
    url_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    key: [64]u8 = undefined,
    key_len: usize = 0,

    fn send(ctx: ?*anyopaque, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) anyerror!HttpResponse {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.method = method;
        @memcpy(self.url[0..url.len], url);
        self.url_len = url.len;
        const b = body orelse "";
        @memcpy(self.body[0..b.len], b);
        self.body_len = b.len;
        for (headers) |h| {
            if (std.mem.eql(u8, h.name, "x-api-key")) {
                @memcpy(self.key[0..h.value.len], h.value);
                self.key_len = h.value.len;
            }
        }
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.reply) };
    }

    fn transport(self: *Fake) Transport {
        return .{ .ctx = self, .send = send };
    }
};

test "send sms" {
    var fake = Fake{};
    var c = try Client.init(std.testing.allocator, "sgk_test", .{ .base_url = "https://example.test/api/", .transport = fake.transport() });
    defer c.deinit();
    const res = try c.sendSms(&.{"+15551234567"}, "Hi", .{});
    defer res.deinit();
    try std.testing.expectEqual(@as(i64, 1873), res.data().object.get("message_ids").?.array.items[0].integer);
    try std.testing.expectEqual(std.http.Method.POST, fake.method);
    try std.testing.expectEqualStrings("https://example.test/api/send-sms", fake.url[0..fake.url_len]);
    try std.testing.expectEqualStrings("sgk_test", fake.key[0..fake.key_len]);
    try std.testing.expectEqualStrings("{\"recipients\":[\"+15551234567\"],\"message\":\"Hi\"}", fake.body[0..fake.body_len]);
}

test "phone, sim and schedule" {
    var fake = Fake{};
    var c = try Client.init(std.testing.allocator, "k", .{ .base_url = "https://example.test/api", .transport = fake.transport() });
    defer c.deinit();
    const res = try c.sendSms(&.{ "+1", "+2" }, "x", .{ .device_id = "42", .sim_slot = 1, .schedule_at = "2026-12-01T08:00:00Z" });
    defer res.deinit();
    try std.testing.expectEqualStrings("https://example.test/api/devices/42/send-sms", fake.url[0..fake.url_len]);
    try std.testing.expectEqualStrings("{\"recipients\":[\"+1\",\"+2\"],\"message\":\"x\",\"sim_slot\":1,\"schedule_at\":\"2026-12-01T08:00:00Z\"}", fake.body[0..fake.body_len]);
    try std.testing.expectError(error.NoRecipients, c.sendSms(&.{}, "x", .{}));
    try std.testing.expectError(error.MissingApiKey, Client.init(std.testing.allocator, "", .{}));
}

test "paths" {
    var fake = Fake{};
    var c = try Client.init(std.testing.allocator, "k", .{ .base_url = "https://example.test/api", .transport = fake.transport() });
    defer c.deinit();
    (try c.cancelMessage("7")).deinit();
    try std.testing.expectEqualStrings("https://example.test/api/messages/7/cancel", fake.url[0..fake.url_len]);
    (try c.listReceivedSms("3")).deinit();
    try std.testing.expectEqualStrings("https://example.test/api/devices/3/get-received-sms", fake.url[0..fake.url_len]);
    (try c.createWebhook("https://my.app/hook", &.{"sms.received"})).deinit();
    try std.testing.expectEqualStrings("{\"url\":\"https://my.app/hook\",\"events\":[\"sms.received\"]}", fake.body[0..fake.body_len]);
    (try c.deleteWebhook("9")).deinit();
    try std.testing.expectEqual(std.http.Method.DELETE, fake.method);
}

test "api errors" {
    var fake = Fake{ .status = 429, .reply = "{\"success\":false,\"message\":\"Too many requests\"}" };
    var c = try Client.init(std.testing.allocator, "k", .{ .transport = fake.transport() });
    defer c.deinit();
    try std.testing.expectError(error.ApiError, c.getAccount());
    try std.testing.expectEqual(@as(u16, 429), c.last_error.status);
    try std.testing.expectEqualStrings("Too many requests", c.last_error.message);

    fake.status = 502;
    fake.reply = "<html>bad gateway</html>";
    try std.testing.expectError(error.ApiError, c.listDevices());
    try std.testing.expectEqualStrings("HTTP 502", c.last_error.message);
}

test "webhook signature" {
    const raw = "{\"event\":\"sms.received\",\"data\":{\"from\":\"+15551234567\"}}";
    const sig = "sha256=e125c07dfbecb498e8979383d7b9f0815efb128755409794b486d4bbb7199583";
    try std.testing.expect(verifyWebhook(raw, sig, "whsec_test"));
    try std.testing.expect(!verifyWebhook(raw, sig, "other"));
    try std.testing.expect(!verifyWebhook("{}", sig, "whsec_test"));
    try std.testing.expect(!verifyWebhook(raw, "", "whsec_test"));
}
