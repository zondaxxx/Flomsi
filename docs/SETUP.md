# Настройка входа через Google и Microsoft и подписи Android

Без этих шагов Flomsi собирается и работает, но кнопок «Continue with Google» и «Sign in with Microsoft»
нет (вход только по паролю приложения), а APK каждого выпуска подписан своим ключом (перед обновлением
старую версию приходится удалять). Всё делается один раз.

## 1. Ключ подписи Android

Нужен для Google-клиента Android и для обновления APK поверх старого.

1. На Маке:
   ```
   keytool -genkeypair -v -keystore ~/flomsi-release.jks -storetype PKCS12 -alias flomsi -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Flomsi"
   ```
   Если `keytool` не найден: `"/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"` или
   `brew install openjdk`. Придумайте один пароль.
2. SHA-1 ключа: `keytool -list -v -keystore ~/flomsi-release.jks -alias flomsi | grep SHA1` — скопируйте.
3. `base64 -i ~/flomsi-release.jks | pbcopy` — это значение секрета `FLOMSI_ANDROID_KEYSTORE_B64`.
4. Сохраните `flomsi-release.jks` и пароль вне репозитория. Потеряете — обновлять поверх старой версии
   будет нельзя.
5. Перед первой сборкой с этим ключом удалите текущий Flomsi с телефона.

## 2. Google (console.cloud.google.com)

1. Создайте проект **Flomsi**.
2. APIs & Services → Library → **Gmail API** → Enable.
3. Google Auth Platform → **Get started**: App name **Flomsi**, support email — ваш Gmail; Audience
   **External**; contact email — ваш Gmail; принять → **Create**.
4. **Branding**: логотип и домены не заполнять.
5. **Audience → Test users → Add users**: все Gmail-адреса, с которыми будете проверять.
6. **Data access → Add or remove scopes**: в «Manually add scopes» введите `https://mail.google.com/`,
   отметьте `openid` и `.../auth/userinfo.email` → Update → **Save**.
7. **Clients → Create client**, три раза:
   1. **Desktop app**, «Flomsi desktop». **Сразу скачайте JSON** (секрет показывается один раз):
      `client_id` → `FLOMSI_GOOGLE_CLIENT_ID`, `client_secret` → `FLOMSI_GOOGLE_CLIENT_SECRET`.
   2. **iOS**, «Flomsi iOS», Bundle ID `dev.zonda.mailApp`. App Store ID и Team ID пустые, **App Check
      выключен** (установленная не из App Store сборка переподписывается). Client ID →
      `FLOMSI_GOOGLE_IOS_CLIENT_ID`.
   3. **Android**, «Flomsi Android», package `dev.zonda.mail_app`, SHA-1 из шага 1.2 → Create. Затем
      откройте клиента → **Advanced settings → Enable custom URI scheme** → Save. Client ID →
      `FLOMSI_GOOGLE_ANDROID_CLIENT_ID`.
8. Client ID вводите целиком, вместе с `.apps.googleusercontent.com`.

## 3. Microsoft (по желанию — для кнопки Outlook)

1. Войдите на **entra.microsoft.com**. Если каталога нет, заведите бесплатный Azure-аккаунт
   (azure.microsoft.com/free) — появится «Default Directory».
2. **App registrations → New registration**: имя **Flomsi**; Supported account types — **«Accounts in
   any organizational directory and personal Microsoft accounts»**; Redirect URI — платформа **Public
   client/native (mobile & desktop)**, значение `http://localhost` → **Register**.
3. **Application (client) ID** → `FLOMSI_MICROSOFT_CLIENT_ID`.
4. **Authentication → Mobile and desktop applications → Add URI**: `msal<client-id>://auth` (ID сразу
   после `msal`) → Save. «Allow public client flows» оставить No.
5. **API permissions → Add a permission → Microsoft Graph → Delegated**: `IMAP.AccessAsUser.All`,
   `SMTP.Send`, `offline_access`, `openid`, `email`, `profile` → Add.
6. Client secret и сертификат **не создавать**.

## 4. Секреты GitHub

Репозиторий → Settings → Secrets and variables → Actions → New repository secret:

| Секрет | Откуда |
|---|---|
| `FLOMSI_GOOGLE_CLIENT_ID` | 2.7.1 |
| `FLOMSI_GOOGLE_CLIENT_SECRET` | 2.7.1 |
| `FLOMSI_GOOGLE_IOS_CLIENT_ID` | 2.7.2 |
| `FLOMSI_GOOGLE_ANDROID_CLIENT_ID` | 2.7.3 |
| `FLOMSI_MICROSOFT_CLIENT_ID` | 3.3 (по желанию) |
| `FLOMSI_ANDROID_KEYSTORE_B64` | 1.3 |
| `FLOMSI_KEYSTORE_PASSWORD` | 1.1 |

## 5. Первая проверка и публикация

1. Запустите сборку (push или тег `v*`) и поставьте macOS, iOS и Android.
2. На каждом войдите тестовым пользователем: есть кнопка «Continue with Google» → выбор аккаунта →
   предупреждение о непроверенном приложении (Advanced → Go to Flomsi) → на экране согласия оставьте
   галочку Gmail → во Flomsi заполняются Входящие.
3. Пока приложение в режиме Testing, войти могут только тестовые пользователи, и доступ истекает через
   7 дней. Поэтому сразу после проверки: **Google Auth Platform → Audience → Publish app → Confirm**
   («In production»).
4. На верификацию **не отправлять**. Ограничения непроверенного приложения: 100 новых пользователей за
   всё время проекта, экран предупреждения при входе; токены при этом не истекают каждую неделю. Клиенты,
   которыми не пользовались 6 месяцев, Google удаляет.
