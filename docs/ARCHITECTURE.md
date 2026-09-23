# Архитектура

Решение принято 22.09.2026, дизайн пересмотрен в тот же день.

## Дизайн: F1 · Editor

История: «E · Mono Glass» (стекло, орбы, неон) отброшено как «нейросетевое»; чистый macOS-натив на macos_ui отброшен как безликий.
Выбрано **F1 · Editor**: линия Zed / Warp / Sublime. Канва с историей и тремя финальными направлениями (ряд F сверху):
https://claude.ai/artifact/V8X9XpoALxZ8YWNVmhAEWz

Правила F1:
- **Палитра One Dark / One Light** (`app/lib/theme/tokens.dart`, `Scheme`): фон #16181d, панели #1b1e24, границы #262a31, текст #d7dae0 / #8b93a1 / #5f6673,
  синий #74ade8 как единственный акцент; зелёный/жёлтый/красный/фиолетовый/циан только для семантики (статус синка, звезда, ошибка, теги).
- **Шрифты IBM Plex**: Plex Sans для интерфейса, Plex Mono только для данных (время, счётчики, теги, заголовки письма, статус-строка, клавиши).
- **Фрейм**: своя верхняя панель 40px (на macOS со светофорами внутри, тайтлбар прозрачный через macos_window_utils), сайдбар 224, список 440, чтение,
  статус-строка 24px как в редакторе. Панели разделены линиями 1px, без карточек и радиусов больше 5px.
- **Никакого декора**: ни стекла, ни свечений, ни `//` и `>` в интерфейсе. Клавиши показываются подписью рядом с действием в тулбаре, в палитре и в статус-строке.

Анимации (`app/lib/theme/motion.dart`): 120–180 мс, easeOutCubic, все отключаются при «уменьшить движение». Где они есть и зачем:
выделение строки при j/k (AnimatedContainer), схлопывание строки при архивации и подъём новых (AnimatedList), смена письма в панели чтения
(fade + подъём 6px), стаггер сообщений треда по 40 мс, вход палитры и окна аккаунта, пульс точки синка, появление точки непрочитанного.
Ничего не движется само по себе без действия пользователя, кроме индикатора синка.

Открытые референсы: Zed, Warp, Linear, Raycast, aerc/neomutt; Apple Design Resources (macOS 26/27 Figma kit) для метрик окна;
open-source почтовики на Flutter: Maily / enough_mail_app, tmail-flutter.

## Стек

| Слой | Технология | Почему |
|---|---|---|
| Ядро | Rust (`core/`) | IMAP/MIME/SQLite/секреты не зависят от UI; один бинарь на 4 платформы |
| UI | Flutter (`app/`) | Один рендер на четырёх платформах; фрейм F1 общий, адаптив по ширине |
| Мост | flutter_rust_bridge v2; на macOS dylib собирает run-script фаза Xcode (`scripts/build_bridge_macos.sh`) | Без CocoaPods и cargokit. Async-стримы событий синка из ядра в UI |
| Окно macOS | macos_window_utils | Прозрачный тайтлбар, светофоры внутри верхней панели F1 |
| База | SQLite + FTS5 | Оффлайн-кэш, полнотекстовый поиск, одна файловая база на профиль |
| Секреты | OS keychain (`keyring`) | Токены никогда не лежат в SQLite |

Запасной вариант UI: Tauri 2. Ядро при этом не меняется.

## Ядро: модули `mailcore`

```
model      типы: Account, Folder, Message, Thread, Label, Flags, Op
sanitize   ammonia: HTML писем без script/style/form/iframe, remote-картинки → data-blocked-src
compose    Draft: reply / reply-all / forward, In-Reply-To + References, цитирование, вложения, MIME через lettre
files      безопасные имена файлов для вложений, `name (1).ext` при совпадении
smtp       lettre: 465 implicit TLS, 587 STARTTLS, PLAIN/LOGIN или XOAUTH2; check() входит без отправки
diagnose   сырая ошибка → вид (auth/network/tls/server/local), заголовок и подсказка по провайдеру
storage    SQLite: схема, миграции, upsert, запросы, FTS5, outbox
search     язык запросов `from:anna has:attachment before:2026-09` → SQL
threading  JWZ-lite по Message-ID / References, фолбэк на тему
provider   trait Provider + реализации: imap (сейчас), gmail_api, jmap, graph (позже)
sync       SyncEngine: provider → store, проигрывание outbox, события
auth       OAuth2 PKCE (loopback на десктопе), XOAUTH2 для IMAP
secrets    обёртка над keyring
```

Публичный фасад: `Core::open(data_dir)` → `add_account`, `sync_now`, `threads(query)`, `apply(op)`, `events()`.

## Мост (`app/rust` = crate `mail_bridge`)

Тонкие DTO над `mailcore::Core` в `app/rust/src/api/mail.rs`. После правок API: `make bridge`
(`flutter_rust_bridge_codegen generate`). Dart-код попадает в `app/lib/src/rust/`, Rust-глю в `app/rust/src/frb_generated.rs`.
Enum с данными в DTO не используем: кодогенератор тогда требует `freezed`; события синка идут плоской структурой с полем `kind`.

Как библиотека попадает в приложение:
- **macOS**: фаза «Build Rust bridge» в таргете Runner (последняя в списке) запускает `scripts/build_bridge_macos.sh`:
  `cargo build` в `app/rust` (debug для Debug-конфигурации, иначе release), копия `libmail_bridge.dylib` в `Contents/Frameworks`, ad-hoc codesign.
  Dart открывает её по явному пути рядом с исполняемым файлом (`RustRepository._bundledLibrary`).
- **iOS**: фаза «Build Rust bridge» стоит ПЕРВОЙ в таргете Runner и запускает `scripts/build_bridge_ios.sh`: `cargo build --target`
  для каждой архитектуры из `$ARCHS` (arm64 устройства, arm64 и x86_64 симулятора), `lipo` в `$BUILT_PRODUCTS_DIR/libmail_bridge.a`.
  Линковка через `OTHER_LDFLAGS = -force_load libmail_bridge.a -framework Security -lresolv` в `ios/Flutter/{Debug,Release}.xcconfig`.
  Скрипт снимает переменные Xcode (`SDKROOT`, `*_DEPLOYMENT_TARGET`, `CC`…), иначе rustc не может собрать host-крейты.
  На iOS keyring использует data-protection keychain: фича `protected` включена target-зависимостью в `core/mailcore/Cargo.toml`.
  Dart открывает символы из самого исполняемого файла (`ExternalLibrary.process`).
- **Android**: Gradle-таск `cargoNdk` в `android/app/build.gradle.kts` вызывает `cargo ndk -t arm64-v8a -t x86_64 -o src/main/jniLibs build --release`
  перед `preBuild`; `jniLibs/` в .gitignore. Нужны `cargo-ndk`, NDK и rust-таргеты `aarch64-linux-android`, `x86_64-linux-android`.
- **Windows**: `windows/runner/CMakeLists.txt` собирает `mail_bridge.dll` через `cargo build --release` и копирует рядом с exe;
  `windows/CMakeLists.txt` кладёт dll в бандл при install. Загрузчик flutter_rust_bridge открывает `mail_bridge.dll` из папки приложения.

Заметка про окружение: Homebrew на этой машине x86_64 под Rosetta (Tier 3), `brew install cocoapods` и `gem install cocoapods`
(системный Ruby 2.6, `nkf` не собирается) падают. Backend native-assets пробовали: Flutter 3.47 не запускает `hook/build.dart`
корневого пакета, поэтому остановились на run-script фазе.

## Принципы

1. **Local-first.** Любое действие сначала применяется к локальной базе и пишется в `outbox`. Синк проигрывает outbox на сервер с идемпотентными ключами. Ожидающая локальная операция побеждает до подтверждения сервером; флаги сверяются по `MODSEQ`.
2. **Инкрементальный синк.** IMAP: `UIDVALIDITY` + `UIDNEXT` + `CONDSTORE`/`QRESYNC` где поддерживается. Gmail API: `historyId`. Graph: delta-ссылки. JMAP: `state`.
3. **Пуш.** В приложении (`RustRepository.startBackgroundSync`): синк при старте, затем на каждый аккаунт цикл IMAP `IDLE` на INBOX
   (`wait_for_change`, перезаход каждые 25 минут, backoff 30 с → 5 мин при ошибках), периодический полный синк раз в 10 минут,
   и отправка outbox через 2 секунды после локального действия. Все синки идут через один замок, чтобы не плодить IMAP-соединения.
   Мобильные: пока приложение свёрнуто, ОС останавливает процесс; настоящий пуш на iOS без сервера невозможен, опциональный relay в поздней фазе.
4. **Безопасность писем.** HTML чистится в ядре (`ammonia`, модуль `sanitize`): без script/style/form/iframe и обработчиков, ссылки только http/https/mailto/cid,
   внешние картинки заменяются на `data-blocked-src` и грузятся только по кнопке «Load images». Рендер в приложении через `flutter_widget_from_html_core`
   (чистый Dart, без WebView и без JavaScript), ссылки открываются во внешнем браузере через `url_launcher`.
5. **Секреты.** Refresh-токены и пароли приложений только в keychain/keystore/Credential Manager. Логи не выше Info в debug и
   Warn в release (`mailcore::logging::max_level`): async-imap на trace пишет каждую команду, включая LOGIN с паролем.
   mailctl всегда глушит `async_imap`. Если ядро не открылось, приложение показывает экран ошибки с «Retry»,
   демо-почта только по флагу `MAIL_MOCK`.
   HTML: относительные и protocol-relative URL выбрасываются, у `<img>` белый список источников (`cid:` всегда, http(s)
   только после «Load images»), атрибуты разбираются честно (в значениях бывает `>`), в CSS только простые токены без
   `url`, экранирования и скобок правил; встроенные картинки ограничены 5 МБ на штуку и 20 МБ на письмо.
6. **Вложения.** Парсер пишет метаданные каждой не-телесной MIME-части в `attachments` (порядок mail-parser = `idx`).
   Часть с Content-ID, на которую ссылается HTML через `cid:`, считается встроенной: она рисуется в письме как `data:`-картинка
   (только растровые форматы, SVG нет) и не показывается в списке вложений; скрепка в списке тредов только для настоящих вложений.
   Сырое письмо (`raw_messages`, zlib) кладётся при синке, если в нём есть части и оно не больше 2 МБ; остальные докачиваются
   с сервера при открытии вложения (кэш до 32 МБ, сверка Message-ID против смены UIDVALIDITY). Копии одного письма в разных папках
   (INBOX и All Mail у Gmail) делят один сырой экземпляр через Message-ID. «Открыть» пишет файл в `<data>/files/<id>-<idx>/`
   и отдаёт системе (десктоп) или в share sheet (телефоны); «Сохранить» кладёт в Downloads под свободным именем.
   Пересылка берёт настоящие вложения оригинала ссылками `(message_id, idx)`, байты читаются только при отправке.
7. **Черновики.** Композер сохраняет черновик на устройстве (таблица `drafts`, JSON `compose::Draft`) через 0,7 с после паузы
   в наборе. Esc и × закрывают с сохранением, «Discard» удаляет, успешная отправка удаляет. Нетронутый шаблон (открыли ответ
   и закрыли) не сохраняется. Папка Drafts в сайдбаре показывает эти черновики; синхронизация с серверной папкой Drafts
   через IMAP APPEND пока не сделана, черновики живут только на этом устройстве.
8. **Настройки.** Лист настроек (⌘, · палитра · шестерёнка в сайдбаре · меню «…» на телефоне): имя и подпись аккаунта,
   удаление аккаунта в два клика, пресет клавиш (vim / gmail), тема. Подпись ядро ставит в новое письмо, ответ и пересылку
   под строкой `-- ` над цитатой. Тема и пресет хранятся в `settings` и восстанавливаются при старте.
11. **Модель Gmail.** В Gmail одно письмо лежит в нескольких «папках»-метках (INBOX, All Mail, Sent Mail, метки), у каждой
   копии свой UID. Ядро хранит копии, но считает и показывает письма по `dedup_key` (X-GM-MSGID при X-GM-EXT-1, иначе
   Message-ID). Прочитанность берётся из копии во Входящих. Архив Gmail = переписки из All Mail без писем во Входящих.
   Флаги уходят одним STORE на письмо, а MOVE в Корзину или Спам один на письмо. Адресуется копия из All Mail, потому что
   её UID стабилен, а UID во Входящих мог уже исчезнуть. Архив снимает метку Inbox, перенос из All Mail только добавляет
   метку. Спам и Корзина синхронизируются с окном 50 и держат свои переписки отдельно: удалённый ответ или спам
   «Re: …» не вклеивается в живой тред. Письма вставляются от старых к новым, чтобы корень треда был до ответов.
   Каждая синхронизация догружает пропущенные UID выше нижней границы кэша. Имена папок в modified UTF-7 декодируются
   и для показа, и для определения роли («Корзина»).
10. **Move и Snooze.** `l` / «Move» открывает палитру с папками аккаунта (у Gmail это ярлыки поверх IMAP) и кладёт
   MOVE в outbox; копии в Sent, Drafts и All Mail не трогаются. `h` / «Snooze» прячет тред из инбокса до выбранного
   времени (позже сегодня, завтра, выходные, следующая неделя). Отложенное живёт на устройстве в `snoozes` с ключом по
   Message-ID корня треда, поэтому переживает пересборку кэша; в сайдбаре есть «Snoozed» (`in:snoozed`). В срок тред
   возвращается в инбокс наверх (сортировка по времени пробуждения) и один раз помечается непрочитанным; архив,
   удаление и перенос отменяют отложенное. Таймер в `RustRepository` будит к ближайшему сроку.
9. **Тесты протоколов.** В ядре есть скриптованные IMAP и SMTP серверы поверх TLS (сертификат rcgen в момент теста):
   полный синк, выгрузка outbox (STORE/MOVE), смена UIDVALIDITY, IDLE, APPEND, отправка со STARTTLS и неявным TLS,
   Bcc только в конверте. `connect_trusting` / `send_trusting` добавляют доверенный корень (частный CA, локальный мост);
   обычные вызовы проверяют сертификат по web PKI. Фейковый IMAP умеет режим STARTTLS (порт без TLS, как 143 и Proton Bridge).
12. **Первый вход.** У аккаунта своя защита соединения для IMAP и SMTP (`tls` с первого байта или `starttls`) и флаг
   локального моста: сертификат моста на этом компьютере (Proton Bridge, 127.0.0.1:1143/1025) принимается как есть, но
   только для loopback-адресов, подписи рукопожатия всё равно проверяются. Форма добавления заполняет серверы по домену
   (Gmail, iCloud, Outlook с честной пометкой, Yandex, Mail.ru и родня, Fastmail, Proton), проверяет вход в IMAP, потом
   в SMTP, и показывает ошибку словами (`diagnose`) с ответом сервера под катом. Повторное добавление адреса
   отказывается до записи в keychain. Аккаунт, чей пароль сервер отверг, «паркуется»: без IDLE, таймера и выгрузки
   outbox, чтобы повторные попытки не заблокировали ящик; пароль меняется в настройках (сначала проверка входа, потом
   запись) или «Try again». Строка статуса говорит правду: no accounts, not synced yet, sign-in needed, sync failed.

13. **Каждый день.** Событие синка перезагружает провайдеры, но список, открытый тред и начатый быстрый ответ
   остаются на экране (`skipLoadingOnReload`, `.value` вместо `asData`). Запрос со словами, отправителем, датой,
   звездой или меткой без `in:` ищет во всех папках, кроме Spam и Trash. Клавиши читаются сначала по набранному
   символу, затем по месту клавиши на US-раскладке, поэтому `e`, `#`, `/`, `g i` работают на «Русской» без
   переключения; AltGr на Windows печатает символ, а не шорткат. Подсказки клавиш берутся из активного кеймапа
   (⌘ только на macOS), начатая последовательность (`g …`) показывает в статусной строке, что может идти дальше.
   j/k и стрелки в палитре прокручивают к выбранной строке; палитра не выше 60% окна.

14. **Соединения не виснут.** Под TLS лежит сторож (`provider/watchdog.rs`): чтение или запись, которые минуту
   не двигаются, обрывают операцию с `TimedOut`; большое письмо на медленной сети при этом качается сколько нужно.
   На время IDLE сторож выключен, а умершего собеседника ловит TCP keepalive. Шаги подключения ограничены 30 с.
   Ошибка ввода-вывода останавливает синк аккаунта, а не валит папку за папкой. Перед IDLE ядро сравнивает UIDNEXT
   с тем, что видел последний синк, и сразу говорит о пропущенной почте; IDLE перезаходит каждые 10 минут. В
   приложении у каждого аккаунта своя очередь, аккаунты синкаются параллельно, у очереди есть крайний срок; при
   возвращении приложения на экран идёт синк, на телефоне список тянется вниз для обновления.

15. **Без потерь.** Операция в outbox помнит UIDVALIDITY своей папки и все свои локальные копии (у Gmail одно
   письмо лежит под несколькими метками): после перестройки папки на сервере она не трогает чужое письмо, а
   сдаётся. Каждая неудача считает попытку, до десяти; окончательный отказ (папки нет, TRYCREATE) снимает операцию
   сразу. Снятая операция остаётся в базе в состоянии «откатить», пока её папки не придут с сервера заново (даже
   если синк оборвётся или эта папка обычно не синкается): письмо, ушедшее из папки только локально, скачивается
   обратно, флаги перечитываются, пользователь один раз видит, что не удалось. Пока операция ждёт, синк не
   перетирает её флаги и не возвращает перемещённое письмо, а с CONDSTORE не двигает HIGHESTMODSEQ через
   отложенное. STORE и EXPUNGE идут командами с проверкой OK (async-imap не смотрит на статус в конце потока
   ответов); чисто закрытое соединение и SELECT без UIDVALIDITY считаются обрывом. Без MOVE перемещение делится на
   COPY и удаление оригинала, и COPY не повторяется; без UIDPLUS EXPUNGE идёт, только если помеченное `\Deleted`
   письмо в папке одно наше, иначе оно остаётся помеченным (такие письма здесь считаются удалёнными). У исходящего письма свой Message-ID на домене отправителя;
   после SMTP всё остальное (копия в Sent, флаг «отвечено») только предупреждает и никогда не выглядит как неудачная
   отправка. Копия в Sent кладётся один раз: сначала поиск по Message-ID; Gmail и Microsoft 365 (по SMTP-серверу,
   которым ушло письмо) кладут её сами. Домен в Message-ID записывается в ASCII (punycode).

## Схема базы (v8)

```
accounts(id, kind, email, display_name, imap_host, imap_port, smtp_host, smtp_port, auth_kind, created_at,
         signature)                                                    -- signature: v4
folders(id, account_id, remote_name, role, uidvalidity, uidnext, highest_modseq, last_sync_at)
messages(id, account_id, folder_id, uid, message_id, thread_id, subject, from_name, from_addr,
         to_json, cc_json, date, snippet, flags, has_attachment, size)
bodies(message_id, text, html)
attachments(message_id, idx, name, mime, size, content_id, inline)   -- v2
raw_messages(message_id, data)                                        -- v2, zlib RFC 822
drafts(id, account_id, kind, draft_json, updated_at)                  -- v3
settings(key, value)                                                  -- v4: theme, keymap
snoozes(account_id, thread_key, thread_id, until, woke)               -- v5
trigger messages_fts_cleanup: DELETE из messages чистит messages_fts  -- v6
messages.gm_msgid, messages.dedup_key, folders.selectable            -- v7
accounts.imap_security, accounts.smtp_security, accounts.local_bridge -- v8
threads(id, account_id, subject, subject_norm, last_date, msg_count, unread_count, snippet, has_attachment, starred, participants)
labels(id, account_id, name, color) ; message_labels(message_id, label_id)
messages_fts(subject, from_text, to_text, body)   -- FTS5
outbox(id, account_id, op_json, created_at, attempts, last_error, done)
```

Миграции по `PRAGMA user_version`. Переход v1 → v2 сбрасывает кэш писем (аккаунты, ярлыки и outbox остаются, у папок
обнуляется UIDVALIDITY): старые строки не знают своих вложений, а сервер остаётся источником правды, так что следующий синк
заново качает окно из 200 последних писем на папку. Переход v2 → v3 только добавляет `drafts`, v3 → v4 добавляет подпись аккаунта и `settings`, v4 → v5 добавляет `snoozes`, v5 → v6 пересобирает поисковый индекс и ставит триггер его очистки, v6 → v7 добавляет ключ письма и пересчитывает треды, v7 → v8 добавляет защиту соединения и флаг локального моста (у старых аккаунтов TLS, SMTP по порту).
Все шаги миграции идут одной транзакцией: оборванное обновление оставляет прежнюю схему. Базу с `user_version` новее,
чем знает сборка, приложение и mailctl не открывают.

## Раскладка UI

| Ширина | Панели |
|---|---|
| ≥ 1100 | папки · список · чтение |
| 700–1099 | список · чтение |
| < 700 | одна панель, стек навигации |

Слои UI: `features/shell/editor_shell.dart` (фрейм F1: верхняя панель, сайдбар, статус-строка, адаптив), общие тела панелей `ThreadListBody`,
`ThreadBody`, `CommandPalette`, `AddAccountSheet`; действия и команды в `shell_actions.dart`; цвета из `Scheme` (`theme/tokens.dart`),
движение из `theme/motion.dart`. `KeyScope` и кеймап из `keymaps/*.json` (пресет по умолчанию `vim`) одинаковы везде.

## Фазы

0. Спайк: IMAP-синк одного ящика в SQLite + стеклянный список во Flutter. Цель: мост и производительность блюра на Android.
1. MVP macOS: Gmail + IMAP, единый инбокс, чтение, архив, ответ, поиск, кеймап, палитра.
2. iOS и Android: свайпы, фоновое обновление, композер-лист.
3. Windows, Outlook (Graph), JMAP, правила, snooze, сниппеты.
4. Светлая тема, календарные приглашения, автоматизация.

## Сборки и CI

Репозиторий: https://github.com/zondaxxx/Flomsi. Все сборки идут через GitHub Actions (`.github/workflows/ci.yml`):
`core` (fmt, clippy, tests, mailctl для Linux), `app-check` (analyze, tests), `macos` (release, артефакт `Flomsi-macOS`),
`ios` (release без подписи), `android` (apk, артефакт `Flomsi-android`), `windows` (zip, артефакт `Flomsi-windows`).
Симуляторная сборка iOS в release невозможна («Release mode is not supported for simulators»), поэтому CI собирает device-бинарник.
Локальные сборки нужны только для скриншотов. В коммитах только авторство владельца репозитория, без атрибуции ассистента.

## Известные риски

- **Верификация Google.** Scope `gmail.modify` restricted: для публичного релиза нужна верификация и, вероятно, CASA-аудит. До этого 100 тестовых пользователей.
- **iOS фон.** IDLE в фоне не живёт. Только Background App Refresh.
- **HTML-письма.** Главный вектор атаки. Санитайзер и WebView без JS обязательны с первого коммита.
