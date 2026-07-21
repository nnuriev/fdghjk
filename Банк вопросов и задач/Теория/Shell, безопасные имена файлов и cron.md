---
aliases:
  - "Теоретический вопрос: Shell, безопасные имена файлов и cron"
tags:
  - область/основы-cs
  - тема/unix
  - тип/вопрос
статус: черновик
---

# Shell, безопасные имена файлов и cron

## Вопрос

Как безопасно искать файлы shell-инструментами и запускать периодическую задачу через cron?

## Короткий ориентир

`find` отбирает filesystem entries, а `grep` ищет содержимое; unquoted glob shell разворачивает до запуска команды. Безопасный pipeline не делит имена по пробелам. Cron интерпретирует пять временных полей и запускает команду с ограниченным environment, поэтому job явно задаёт paths, overlap policy и сбор результата.

Полные разборы:

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Shell, поиск файла и cron — `00:29:21–00:32:09`|MERLION: shell и cron]]

## Варианты follow-up

- Почему glob в аргументе `find` нужно заключать в кавычки?
- Как безопасно передать найденные пути с пробелами другой программе?
- В каком environment и timezone исполняется cron job?

## Варианты формулировки и происхождение

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Shell, поиск файла и cron — `00:29:21–00:32:09`|MERLION, shell и cron]].

## Источники

- [crontab](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/crontab.html) — The Open Group, POSIX.1-2017, проверено `2026-07-19`.
- [find](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html) — The Open Group, POSIX.1-2017, проверено 2026-07-19.
