"""Build the versioned GoTrue mail templates; --check detects generated drift."""
import argparse
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'supabase' / 'email_templates'
DELETE_CONTEXT = 'https://eatova.de/auth/email/account-deletion'
RESET_CONTEXT = 'https://eatova.de/auth/email/password-reset'


def purpose(deletion, reset, fallback):
    return ('{{ if eq .RedirectTo "' + DELETE_CONTEXT + '" }}' + deletion
            + '{{ else if eq .RedirectTo "' + RESET_CONTEXT + '" }}' + reset
            + '{{ else }}' + fallback + '{{ end }}')


def paragraph(text):
    return f'<p style="margin:0 0 20px;font-size:16px;line-height:1.6;">{text}</p>'


def render(title, intro, *, code=False, note='', action=False):
    # Tables and inline fallbacks keep Outlook usable without media queries.
    # No tracking images, remote fonts, scripts or authentication links for OTPs.
    content = paragraph(intro)
    if code:
        content += '''<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr>
<td class="code" align="center" style="background:#EAE5FF;color:#352354;border-radius:12px;padding:22px 8px;font-family:Consolas,'Courier New',monospace;font-size:30px;line-height:1.3;font-weight:700;letter-spacing:4px;white-space:nowrap;">{{ .Token }}</td>
</tr></table>
<p class="muted" style="margin:12px 0 24px;color:#625F6D;font-size:14px;line-height:1.5;">Dein Code ist 10 Minuten gültig. Gib ihn nur in der Eatova-App ein und teile ihn mit niemandem.</p>'''
    if action:
        content += '''<table role="presentation" cellspacing="0" cellpadding="0"><tr><td style="background:#6550A8;border-radius:12px;">
<a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:15px 24px;color:#ffffff;font-size:16px;font-weight:700;text-decoration:none;">Einladung annehmen</a>
</td></tr></table>'''
    if note:
        content += f'<p class="muted" style="margin:24px 0 0;color:#625F6D;font-size:14px;line-height:1.6;">{note}</p>'
    return f'''<!doctype html>
<html lang="de"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
<title>{title}</title>
<style>
body,table,td,a {{ -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%; }}
table {{ border-collapse:collapse; }}
a:focus-visible {{ outline:2px solid #6550A8; outline-offset:4px; }}
@media screen and (max-width:480px) {{ .outer {{ padding:20px 12px !important; }} .inner {{ padding:28px 22px !important; }} h1 {{ font-size:25px !important; }} }}
@media (prefers-color-scheme:dark) {{ body,.outer {{ background:#131219 !important; }} .card {{ background:#201E29 !important; }} .inner,.heading {{ color:#F2EFF8 !important; }} .muted,.footer {{ color:#BDB6CB !important; }} .brand,.footer a {{ color:#C6B5FA !important; }} .code {{ background:#36294F !important;color:#F0E9FF !important; }} }}
</style></head>
<body style="margin:0;padding:0;background:#F8F8FC;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td class="outer" align="center" style="padding:40px 16px;background:#F8F8FC;">
<!--[if mso]><table role="presentation" width="520"><tr><td><![endif]-->
<table class="card" role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#FFFFFF;border-radius:16px;">
<tr><td class="inner" style="padding:36px 36px 32px;color:#16151F;word-break:break-word;">
<p class="brand" style="margin:0 0 36px;color:#6550A8;font-size:25px;font-weight:750;letter-spacing:-0.7px;">eatova</p>
<h1 class="heading" style="margin:0 0 16px;color:#16151F;font-size:28px;line-height:1.2;font-weight:700;letter-spacing:-0.5px;">{title}</h1>
{content}
</td></tr></table>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;"><tr><td class="footer" style="padding:24px 12px 0;color:#625F6D;text-align:center;font-size:12px;line-height:1.8;">
Eatova · Ernährung, die zu dir passt.<br>
<a href="https://eatova.de/datenschutz" style="color:#625F6D;text-decoration:underline;">Datenschutz</a> &nbsp;·&nbsp;
<a href="https://eatova.de/impressum" style="color:#625F6D;text-decoration:underline;">Impressum</a> &nbsp;·&nbsp;
<a href="mailto:support@eatova.de" style="color:#625F6D;text-decoration:underline;">Hilfe</a>
</td></tr></table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr></table></body></html>
'''


def templates():
    common = 'Wenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.'
    recovery_title = purpose('Kontolöschung bestätigen', 'Passwort zurücksetzen', 'Deine Identität bestätigen')
    recovery_intro = purpose(
        'Du hast in Eatova die Löschung deines Kontos gestartet. Gib diesen Code in der App ein, um deine Identität zu bestätigen. Die Löschung schließt du dort ab.',
        'Du möchtest ein neues Passwort festlegen. Gib diesen Code in der App ein. Danach kannst du dein neues Passwort wählen.',
        'Gib diesen Code in der App ein, um die Aktion zu bestätigen, die du gerade in Eatova gestartet hast.')
    result = {
        'confirmation': ('Dein Eatova-Code: E-Mail bestätigen', render('Willkommen bei Eatova', 'Ein Schritt noch: Gib diesen Code in der App ein, um deine E-Mail-Adresse zu bestätigen.', code=True, note='Wenn du kein Konto erstellt hast, kannst du diese E-Mail ignorieren.')),
        'recovery': ('Dein Eatova-Sicherheitscode', render(recovery_title, recovery_intro, code=True, note=common + ' Ohne deine Bestätigung wird die angeforderte Aktion nicht abgeschlossen.')),
        'reauthentication': ('Dein Eatova-Code: Passwort ändern', render('Passwort ändern', 'Du möchtest dein Passwort ändern. Gib diesen Code zusammen mit deinem neuen Passwort in der App ein.', code=True, note=common)),
        'email_change': ('Dein Eatova-Code: E-Mail-Adresse ändern', render('E-Mail-Adresse ändern', 'Bestätige den Wechsel zu <strong>{{ .NewEmail }}</strong> mit diesem Code in der App. Du erhältst je einen Code an die bisherige und die neue Adresse. Beide werden benötigt.', code=True, note=common)),
        'magic_link': ('Eatova: Hinweis zu deiner Anmeldung', render('Hinweis zu deiner Anmeldung', 'Für diese Adresse wurde ein Anmelde-Link angefordert. Melde dich in der Eatova-App mit deinem Passwort an. Falls du es vergessen hast, wähle dort „Passwort vergessen“.', note='Eatova verwendet keine Anmelde-Links. Wenn du das nicht warst, kannst du diese E-Mail ignorieren.')),
        'invite': ('Deine Einladung zu Eatova', render('Du bist eingeladen', 'Du hast eine Einladung erhalten, ein Eatova-Konto zu erstellen. Nimm sie an, um deine Einrichtung zu beginnen.', action=True, note='Wenn du diese Einladung nicht erwartet hast, kannst du sie ignorieren.')),
    }
    notifications = {
        'password_changed': ('Dein Passwort wurde geändert', 'Das Passwort für dein Eatova-Konto <strong>{{ .Email }}</strong> wurde geändert.'),
        'email_changed': ('Deine E-Mail-Adresse wurde geändert', 'Die E-Mail-Adresse deines Eatova-Kontos wurde von <strong>{{ .OldEmail }}</strong> zu <strong>{{ .Email }}</strong> geändert.'),
        'phone_changed': ('Deine Telefonnummer wurde geändert', 'Die Telefonnummer deines Kontos <strong>{{ .Email }}</strong> wurde von <strong>{{ .OldPhone }}</strong> zu <strong>{{ .Phone }}</strong> geändert.'),
        'mfa_factor_enrolled': ('Zusätzliche Bestätigung eingerichtet', 'Für dein Konto <strong>{{ .Email }}</strong> wurde eine zusätzliche Bestätigung für die Anmeldung eingerichtet: <strong>{{ .FactorType }}</strong>.'),
        'mfa_factor_unenrolled': ('Zusätzliche Bestätigung entfernt', 'Für dein Konto <strong>{{ .Email }}</strong> wurde eine zusätzliche Bestätigung für die Anmeldung entfernt: <strong>{{ .FactorType }}</strong>.'),
        'identity_linked': ('Anmeldemethode hinzugefügt', 'Dein <strong>{{ .Provider }}</strong>-Konto wurde mit deinem Eatova-Konto <strong>{{ .Email }}</strong> verknüpft.'),
        'identity_unlinked': ('Anmeldemethode entfernt', 'Die Verknüpfung mit <strong>{{ .Provider }}</strong> wurde aus deinem Eatova-Konto <strong>{{ .Email }}</strong> entfernt.'),
    }
    for key, (title, intro) in notifications.items():
        result[key + '_notification'] = ('Eatova: ' + title, render(title, intro, note='Wenn du diese Änderung nicht vorgenommen hast, kontaktiere sofort <a href="mailto:support@eatova.de" style="color:inherit;text-decoration:underline;">support@eatova.de</a>. Gib dabei niemals dein Passwort oder einen Sicherheitscode weiter.'))
    return result


def generated_files():
    values = templates()
    return {
        **{name + '.html': html for name, (_, html) in values.items()},
        'subjects.json': json.dumps({name: subject for name, (subject, _) in values.items()}, ensure_ascii=False, indent=2) + '\n',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    options = parser.parse_args()
    for name, content in generated_files().items():
        path = DESTINATION / name
        if options.check:
            if not path.exists() or path.read_text(encoding='utf-8') != content:
                raise SystemExit(f'Generated template differs: {path.relative_to(ROOT)}')
        else:
            DESTINATION.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
    print('Auth email templates match.' if options.check else 'Built 13 auth email templates.')


if __name__ == '__main__':
    main()
