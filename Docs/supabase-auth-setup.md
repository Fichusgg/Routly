# Supabase auth setup

What has to exist outside the codebase before sign-in works. Until it does, the
app runs in guest mode and every feature still works — the account screen just
says accounts aren't configured.

Nothing in this file has been done for you: it all needs your Apple Developer
and Supabase credentials.

## 1. Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Copy **Project URL** and the **anon / publishable key** from Settings → API.
3. Put both into `Routly/Secrets.plist` (gitignored — copy
   `Secrets.example.plist` if you don't have one yet):

   ```xml
   <key>SupabaseURL</key>
   <string>https://your-ref.supabase.co</string>
   <key>SupabaseAnonKey</key>
   <string>eyJhbGci...</string>
   ```

The anon key is meant to be public. It identifies the project; Row Level
Security is what actually protects data. Do **not** put the service role key
here — that one bypasses RLS entirely.

Email sign-in works with just the above. Nothing in section 2 is needed to run
the app.

## 2. Sign in with Apple — OFF, needs a paid membership

**Currently switched off.** Sign in with Apple requires the
`com.apple.developer.applesignin` entitlement, and that entitlement requires a
paid **Apple Developer Program** membership ($99/yr). Free/personal-team signing
cannot use it — a device build would fail to sign.

So the entitlement file and the `SignInWithAppleButton` have been removed, and
email is the only sign-in path. The supporting code is deliberately still here
and still under test: `Auth/AppleSignIn.swift` (nonce + SHA256) and
`AuthController.signInWithApple`.

### Turning it back on, once you have the membership

1. Recreate `RoutineOrganizer/RoutineOrganizer.entitlements`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>com.apple.developer.applesignin</key>
       <array>
           <string>Default</string>
       </array>
   </dict>
   </plist>
   ```

   and set `CODE_SIGN_ENTITLEMENTS = RoutineOrganizer/RoutineOrganizer.entitlements;`
   on both the Debug and Release configs of the app target (Xcode does this for
   you if you add the capability through Signing & Capabilities).

2. Put the button back in `SignInView.swift` — `import AuthenticationServices`,
   a `@State` nonce, and a `SignInWithAppleButton` that calls
   `auth.signInWithApple(result, nonce:)`. Use `AppleSignIn.sha256(nonce)` for
   `request.nonce` and pass the **raw** nonce to the controller.

3. Enable the capability for the app id
   `com.FilipOscar.Routly` in the Developer portal and
   regenerate the provisioning profile.

4. For Supabase to verify tokens you also need, under Certificates, Identifiers
   & Profiles:
   - a **Services ID** (this becomes the "client id" Supabase asks for),
   - a **Sign in with Apple key** (`.p8`), plus its Key ID and your Team ID.

### Supabase side

Authentication → Providers → Apple:

- **Client IDs**: the app's bundle id, `com.FilipOscar.Routly`.
  Native iOS sign-in sends the bundle id as the audience, so it must be listed
  here or token exchange fails with an audience mismatch.
- **Secret key**: generated from the `.p8` + Key ID + Team ID.

Native Sign in with Apple does not use a redirect URL — the app exchanges
Apple's identity token directly. The nonce handling this requires is already
implemented in `Auth/AppleSignIn.swift`.

## 3. Email sign-in

Authentication → Providers → Email. Leave "Confirm email" on for production;
the app handles the no-session-yet response and tells the person to check their
mail. Minimum password length is enforced client-side at 8 characters, so set
the server minimum to 8 or lower to avoid contradicting the UI.

## 4. Account deletion (required before App Store submission)

App Store guideline 5.1.1(v) requires in-app account deletion for any app that
offers account creation. A client holding only the anon key cannot delete a
user, so the app calls an RPC. Run this once in the SQL editor:

```sql
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
```

Until this exists, "Delete account" in the app surfaces a plain error rather
than pretending to have worked.

## 5. Not needed yet

No tables, no RLS policies, no schema. This phase only establishes identity —
nothing is uploaded. Table design and the RLS policies that go with it belong
to the sync phase, along with the `updatedAt` / `syncedAt` / `deletedAt`
columns that already exist on the local models waiting for them.

Note that RLS is the one place in this stack where a mistake is severe: a
missing policy means one account can read another's schedule. When those tables
arrive they need deliberate testing, not a glance.
