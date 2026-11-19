# Release Nanolight

Open pull requests against `dev`. At 03:23 Perth time (19:23 UTC), the nightly workflow merges the latest `dev` commit into `main` if CI passed for that commit. You can also run **Nightly promotion** from `dev` in Actions.

Once signing is enabled, pushes to `main` and nightly promotions start **Release**. The first release is `v0.3.0`. Later releases increase the patch number when the released files change. Notes link to the original PRs and @mention their authors. Direct commits have their own links.

The workflow signs and notarizes the Apple silicon app and disk image. It checks Gatekeeper, signatures, notarization tickets, and downloads on macOS 15 and 26 before it marks the release as latest. From the second release, it also tests the update from the previous release. The app targets macOS 14 or later.

## Get the Apple credentials

1. Sign in as the Account Holder of an active Apple Developer Program membership. In **Certificates, Identifiers & Profiles → Certificates**, add **Developer ID Application**. Create the certificate signing request on your Mac, upload it, and open the downloaded certificate on the same Mac. [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
2. In **Keychain Access → login → My Certificates**, find the **Developer ID Application** identity. Expand it to check that it has a private key. Select the identity, choose **File → Export Items**, and save it as a password-protected `DeveloperID.p12` outside the Git checkout. Save the password in your password manager.
3. In **App Store Connect → Users and Access → Integrations → App Store Connect API**, request API access if needed. Under **Team Keys**, create a key for Nanolight notarization. Select a role with **Notarize software** access. Save the key ID and issuer ID. Download the `AuthKey_….p8` file and store it securely. Apple lets you download it once. [Apple's team key instructions](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/) · [Role permissions](https://developer.apple.com/help/account/access/roles/)

## Upload the credentials to GitHub

The `release-signing` environment accepts deployments from `main`. Use these commands on your Mac with the GitHub CLI signed in to your account. Set the two file paths to the files you exported and downloaded. GitHub CLI prompts for the other three values. Keep the files and values out of Git, Actions logs, and chat. [GitHub guide to Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets?tool=cli)

```sh
repo=oscardobsonbrown/nanolight
p12_path=/path/to/DeveloperID.p12
p8_path=/path/to/AuthKey_YOURKEYID.p8

base64 < "$p12_path" | gh secret set MACOS_CERT_P12 --repo "$repo" --env release-signing
gh secret set MACOS_CERT_PASSWORD --repo "$repo" --env release-signing
gh secret set AC_API_KEY_P8 --repo "$repo" --env release-signing < "$p8_path"
gh secret set AC_API_KEY_ID --repo "$repo" --env release-signing
gh secret set AC_API_ISSUER_ID --repo "$repo" --env release-signing
```

You can check the five secret names with the first command below. After you have added all five, enable releases and start the first build.

```sh
gh secret list --repo "$repo" --env release-signing
gh variable set RELEASE_ENABLED --repo "$repo" --body true
gh workflow run release.yml --repo "$repo" --ref main
```

After **Release** passes, download `nanolight-macos-arm64.dmg` from [the latest release](https://github.com/oscardobsonbrown/nanolight/releases/latest). Open it and drag Nanolight to Applications.
