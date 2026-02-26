# Slack app for Black Thorn (OpenClaw)

This directory contains the Slack app manifest used to grant Slack access so you can chat with the OpenClaw instance running as **black_thorn** on the server.

Reference: [OpenClaw – Slack](https://docs.openclaw.ai/channels/slack).

## 1. Create the Slack app from the manifest

1. Go to [Slack API – Create app](https://api.slack.com/apps?new_app=1).
2. Choose **From an app manifest**.
3. Pick your workspace.
4. Paste the contents of **`manifest.json`** (or upload the file), then complete the flow.

## 2. Enable Socket Mode and get tokens

In the app’s settings:

1. **Socket Mode** – turn **On**.
2. **App-Level Tokens** – create a token with `connections:write`; copy the **App Token** (`xapp-...`).
3. **OAuth & Permissions** – install the app to your workspace and copy the **Bot User OAuth Token** (`xoxb-...`).

## 3. Configure OpenClaw (on the server as black_thorn)

On the server, as user **black_thorn**, configure OpenClaw to use Slack. For example in `~/.openclaw/config.json` (or the path OpenClaw uses):

```json
{
  "channels": {
    "slack": {
      "enabled": true,
      "mode": "socket",
      "appToken": "xapp-...",
      "botToken": "xoxb-..."
    }
  }
}
```

Or set env vars (default account only):

```bash
export SLACK_APP_TOKEN=xapp-...
export SLACK_BOT_TOKEN=xoxb-...
```

## 4. Subscribe to bot events

In the Slack app: **Event Subscriptions** → **Subscribe to bot events**, add:

- `app_mention`
- `message.channels`, `message.groups`, `message.im`, `message.mpim`
- `reaction_added`, `reaction_removed`
- `member_joined_channel`, `member_left_channel`
- `channel_rename`
- `pin_added`, `pin_removed`

Ensure **App Home** → **Messages Tab** is enabled for DMs.

## 5. Start the gateway

As **black_thorn** on the server:

```bash
openclaw gateway
```

For DMs, use pairing: `openclaw pairing approve slack <code>` (see [Pairing](https://docs.openclaw.ai/channels/pairing)).

## Troubleshooting

- **"channel resolve failed; using config entries. Error: missing_scope"**  
  OpenClaw could not resolve channel names at startup. Socket Mode still works. To clear the warning: in the Slack app go to **OAuth & Permissions**, add the scopes `groups:read`, `im:read`, `mpim:read` if missing (our manifest includes them), then **reinstall the app** to your workspace. Restart the gateway.

- **DMs: no reply**  
  Run `openclaw pairing list slack` on the server; Slack will show a pairing code in the DM. Then run `openclaw pairing approve slack <code>` (with that code). See [Pairing](https://docs.openclaw.ai/channels/pairing).

- **Channel: bot online but no reply**  
  Check **groupPolicy** and channel allowlist in `~/.openclaw/openclaw.json` (`channels.slack.channels`). By default the bot may only respond when **mentioned** (`requireMention: true`). Mention the app in the channel (e.g. `@Black Thorn`) or add the channel to the allowlist and relax mention requirement if desired.  
  Quick check: `openclaw channels status --probe` (see [Channel troubleshooting](https://docs.openclaw.ai/channels/troubleshooting)).
