import 'add_account_sheet.dart' show Preset, providerPresets;

/// One step of getting an app password, with the page it happens on.
class GuideStep {
  const GuideStep(this.text, {this.link, this.linkLabel});
  final String text;
  final String? link;
  final String? linkLabel;
}

/// How a provider lets a mail app in with an app password, step by step.
class ProviderGuide {
  const ProviderGuide({
    required this.id,
    required this.name,
    required this.intro,
    required this.steps,
    required this.passwordName,
    this.note,
    this.stripSpaces = false,
  });
  final String id;
  final String name;
  final String intro;
  final List<GuideStep> steps;

  /// What the provider calls the password ("app password", "app-specific password").
  final String passwordName;
  final String? note;

  /// Gmail shows its app passwords in groups of four with spaces.
  final bool stripSpaces;

  Preset get preset => providerPresets[id]!;
}

/// Links are checked before each release.
const providerGuides = <String, ProviderGuide>{
  'gmail': ProviderGuide(
    id: 'gmail',
    name: 'Gmail',
    intro: 'Without Google sign-in, Gmail lets mail apps in with an app password, not your Google password.',
    passwordName: 'app password',
    stripSpaces: true,
    note: 'Work and school accounts may have app passwords turned off.',
    steps: [
      GuideStep(
        'Turn on 2-Step Verification for your Google account.',
        link: 'https://myaccount.google.com/signinoptions/twosv',
        linkLabel: 'Open 2-Step Verification',
      ),
      GuideStep(
        'Create an app password named Flomsi and copy it.',
        link: 'https://myaccount.google.com/apppasswords',
        linkLabel: 'Open app passwords',
      ),
    ],
  ),
  'icloud': ProviderGuide(
    id: 'icloud',
    name: 'iCloud Mail',
    intro: 'iCloud lets mail apps in with an app-specific password, not your Apple Account password.',
    passwordName: 'app-specific password',
    steps: [
      GuideStep(
        'Make sure two-factor authentication is on for your Apple Account.',
      ),
      GuideStep(
        'In Sign-In and Security → App-Specific Passwords, create one named Flomsi.',
        link: 'https://account.apple.com/account/manage',
        linkLabel: 'Open Apple Account',
      ),
    ],
  ),
  'yandex': ProviderGuide(
    id: 'yandex',
    name: 'Yandex Mail',
    intro: 'Yandex lets mail apps in with an app password, not your Yandex ID password.',
    passwordName: 'app password',
    note: 'Addresses at yandex.com use mail.yandex.com and id.yandex.com instead.',
    steps: [
      GuideStep(
        'Allow mail apps to use IMAP.',
        link: 'https://mail.yandex.ru/#setup/client',
        linkLabel: 'Open mail app settings',
      ),
      GuideStep(
        'Create an app password for Mail and copy it.',
        link: 'https://id.yandex.ru/security/app-passwords',
        linkLabel: 'Open app passwords',
      ),
    ],
  ),
  'mailru': ProviderGuide(
    id: 'mailru',
    name: 'Mail.ru',
    intro: 'Mail.ru lets mail apps in with a password for external apps, not your account password.',
    passwordName: 'password for external apps',
    steps: [
      GuideStep(
        'In Security → Passwords for external applications, create one for Flomsi.',
        link: 'https://account.mail.ru/user/2-step-auth/passwords/',
        linkLabel: 'Open passwords for apps',
      ),
    ],
  ),
  'fastmail': ProviderGuide(
    id: 'fastmail',
    name: 'Fastmail',
    intro: 'Fastmail lets mail apps in with an app password.',
    passwordName: 'app password',
    steps: [
      GuideStep(
        'In Settings → Privacy & Security → App passwords, create one with IMAP and SMTP access.',
        link: 'https://app.fastmail.com/settings/security/apppasswords',
        linkLabel: 'Open app passwords',
      ),
    ],
  ),
};
