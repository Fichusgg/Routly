# Google Calendar setup

What has to exist outside the codebase before Google Calendar works. Until it
does, the app behaves exactly as it did: Google is absent from Settings →
Calendars entirely, Apple Calendar keeps working, and nothing is broken or
greyed out.

Nothing in this file has been done for you — it needs your own Google account.

## 1. Google Cloud project

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create
   a project (or pick an existing one).
2. **APIs & Services → Library → Google Calendar API → Enable.**

## 2. OAuth consent screen

**APIs & Services → OAuth consent screen.**

- User type: **External**.
- Fill in app name, user support email, developer contact email.
- **Scopes:** add exactly one —
  `https://www.googleapis.com/auth/calendar.app.created`

  This is the narrowest scope that does the job. It lets Routly create its own
  secondary calendar and read/write events *on the calendars it created* — and
  nothing else in your account. Routly makes one calendar called "Routly" and
  writes only there.

  ⚠️ **Read what the Console says when you add this scope.** It labels each
  scope sensitive or restricted and tells you what verification that triggers.
  Tell me what it says — the answer decides whether publishing needs a review,
  and I'd rather have your screenshot than my recollection.

- **Test users:** add your own Google account. While the app is in *Testing*
  mode you are capped at 100 test users, and **refresh tokens expire after 7
  days** — so a connection that worked last week will ask you to sign in again.
  That is Google's testing-mode behaviour, not a bug in the app; Routly reports
  it as "Routly is signed out of Google" and offers to reconnect.

## 3. OAuth client ID

**APIs & Services → Credentials → Create credentials → OAuth client ID.**

- Application type: **iOS**
- Bundle ID: `com.FilipOscar.Routly`

You'll be given a client ID like
`1234567890-abcdefghijklmnop.apps.googleusercontent.com`.

**No client secret is issued, and that is correct.** An iOS OAuth client is a
*public* client: it cannot keep a secret, so Google doesn't give it one. PKCE is
what proves the token request came from the same app that started the sign-in.
Nothing confidential ships in the binary.

You do **not** need the reversed client ID for anything. Routly derives it from
the client ID, and because sign-in runs in `ASWebAuthenticationSession` — which
intercepts its own callback — there is no URL scheme to register in Info.plist.

## 4. Put it in Secrets.plist

`Routly/Secrets.plist` is gitignored; copy `Secrets.example.plist` if
you don't have one yet.

```xml
<key>GoogleClientID</key>
<string>1234567890-abcdefghijklmnop.apps.googleusercontent.com</string>
```

Rebuild. Settings → Calendars will now list Google Calendar with a **Connect**
button.

## 5. Using it

- **Connect** opens Google's sign-in in a sheet. Granting access switches
  "Add new events here" on automatically.
- From then on, every new event and reminder with a day on it goes to the
  **Routly** calendar in your Google account — no per-event choice, same as
  Apple.
- Edits and deletes in Routly follow. To-dos and repeating items don't go
  across (see Settings → Calendars → "What goes across").
- **Disconnect** revokes the token with Google, forgets the calendar id, and
  switches the destination off. It does not delete events already written —
  they're yours, and silently emptying a calendar is not a thing an app should
  do on a disconnect.

## If you'd rather use your primary calendar

Two lines in `GoogleCalendarConfig`, changed together:

```swift
static let destination: Destination = .primary
static let scope = "https://www.googleapis.com/auth/calendar.events"
```

That writes into the account's main calendar instead of a separate "Routly" one.
It is a broader scope with a heavier verification path, and it puts Routly's
events among everything else, which is why it isn't the default.

## Troubleshooting

| What you see | What it means |
|---|---|
| Google Calendar missing from Settings | No `GoogleClientID` in Secrets.plist, or the app wasn't rebuilt after adding it. |
| "The Google client ID in Secrets.plist isn't in the expected form" | The value must end in `.apps.googleusercontent.com`. You may have pasted a web client ID or the project number. |
| "Routly is signed out of Google" | The refresh token was revoked or expired — most often the 7-day testing-mode expiry. Press Connect again. |
| Sign-in sheet opens and immediately closes | The bundle ID on the OAuth client doesn't match the app's. |
