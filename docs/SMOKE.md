# Проверка на настоящем ящике

Шаги для первого прогона Flomsi на реальном аккаунте. Сначала всё проверяется из терминала через `mailctl`,
с отдельным каталогом данных. Приложение и его пароли при этом не трогаются. Пароль вводите сами в ответ на
приглашение; в файлы и историю shell он не попадает.

## 0. Сборка

```bash
cd core && cargo build -p mailctl --release
```

Дальше `mailctl` означает `core/target/release/mailctl`. Каталог данных для проверки лучше держать отдельно:

```bash
alias fm='core/target/release/mailctl --data-dir ~/flomsi-smoke'
```

## 1. Что говорит сервер

```bash
fm probe --email you@example.com --host imap.example.com
```

Команда входит и показывает:
- что сервер умеет (MOVE, UIDPLUS, CONDSTORE, SPECIAL-USE);
- все папки с атрибутами и ролью, которую им даст Flomsi;
- у каждой папки EXISTS, UIDVALIDITY, UIDNEXT и MODSEQ.

Папки открываются только на чтение (EXAMINE). На что смотреть:
- у Sent, Trash, Drafts и Junk есть роль;
- у Gmail есть `\All`. Если All Mail или Trash скрыты от IMAP, probe так и скажет;
- для ящика с сотнями папок есть `--quick`: он только перечисляет папки.

## 2. Вход в SMTP

```bash
fm check-smtp --email you@example.com --host smtp.example.com
```

По умолчанию используется порт 465 с TLS. На любом другом порту (587, 1025) включается STARTTLS. Письмо при проверке не отправляется.

## 3. Аккаунт

```bash
fm add-imap --email you@example.com --host imap.example.com --smtp-host smtp.example.com
```

Перед сохранением команда проверяет вход в IMAP и в SMTP. Если вход не удался, ничего не сохраняется, а ошибка
объясняется словами. Флаги: `--starttls` включает STARTTLS для IMAP (143, 1143). SMTP выбирает защиту по порту: 465
с TLS, остальные со STARTTLS; `--smtp-starttls` задаёт STARTTLS явно. `--local-bridge` нужен для Proton Bridge.

## 4. Синк и чтение

```bash
fm sync
fm folders
fm ls
fm ls "from:anna has:attachment"
fm show 12
fm save 345 1 --dir ~/Downloads
```

`sync` печатает, сколько писем пришло в каждую папку и сколько занял синк. Ошибки папок выводятся отдельно, при
ошибке команда завершается с кодом 1. `folders` показывает роль каждой папки, сколько писем в кэше и время
последнего синка.

## 5. Действия (проверьте результат в веб-почте)

```bash
fm star 12
fm read 12 --unread
fm archive 12
fm sync
```

Действия сначала применяются локально и уходят на сервер при следующем `sync`. Если на сервере нет папки Archive,
`archive` предложит `fm create-folder --account 1 archive`. Приложение в этом случае спрашивает само.

## 6. Отправка себе

```bash
fm send --account 1 --to you@example.com --subject "Flomsi smoke" --text "hello"
fm sync
fm reply <thread> --text "reply works"
```

Письмо должно появиться во Входящих и один раз в Sent. Gmail и Microsoft 365 кладут копию в Sent сами.

## 7. Новая почта без опроса

```bash
fm idle --account 1
```

Отправьте себе письмо с телефона. `idle` проснётся и досинкает Входящие.

## Если что-то не так

Запишите разговор с сервером:

```bash
fm --wire ~/flomsi-wire.txt sync
```

Что в этой записи:
- пароли, токены и аргументы LOGIN/AUTHENTICATE замаскированы;
- тела писем обрезаны до первых 200 байт;
- **адреса, темы и начало каждого письма остаются.**

Файл создаётся с правами 0600. Прочитайте его, прежде чем кому-то отправлять.

## Настройки популярных ящиков

| Почта | IMAP | SMTP | Пароль |
|---|---|---|---|
| Gmail | imap.gmail.com 993 | smtp.gmail.com 465 | пароль приложения (нужна 2FA) |
| Яндекс | imap.yandex.ru 993 | smtp.yandex.ru 465 | пароль приложения, IMAP включается в настройках |
| Mail.ru, BK, Inbox, List | imap.mail.ru 993 | smtp.mail.ru 465 | пароль для внешнего приложения |
| iCloud | imap.mail.me.com 993 | smtp.mail.me.com `--smtp-port 587` | пароль приложения |
| Fastmail | imap.fastmail.com 993 | smtp.fastmail.com 465 | пароль приложения |
| Proton Bridge | 127.0.0.1 `--port 1143 --starttls --local-bridge` | 127.0.0.1 `--smtp-port 1025` | пароль из Bridge |

Outlook.com и Microsoft 365 не принимают пароль по IMAP, для них нужен OAuth. Он ещё не сделан.

## Уборка

```bash
fm remove 1
rm -rf ~/flomsi-smoke
```

`remove` удаляет аккаунт, его кэш и пароль из связки ключей.
