---
aliases:
  - "Теоретический вопрос: Уровни тестирования — unit, integration и end-to-end"
tags:
  - область/бэкенд
  - тема/тестирование
  - тип/вопрос
статус: черновик
---

# Уровни тестирования — unit, integration и end-to-end

## Вопрос

Какие границы и риски проверяют unit, integration и end-to-end tests и как собрать из них стратегию тестирования?

## Короткий ориентир

Unit test держит узкую контролируемую границу, integration test проверяет взаимодействие с реальным компонентом или протоколом, end-to-end test проходит критический пользовательский поток через развёрнутую систему. Уровни не заменяют друг друга: для каждого заранее фиксируют риск, среду, oracle и стоимость диагностики сбоя.

Полные разборы:

- [[20 Бэкенд/Стратегия тестирования backend|Стратегия тестирования backend]]

## Варианты follow-up

- Чем unit test отличается от integration test по границе системы?
- Какие контракты выгоднее проверять integration tests?
- Какие критические потоки оправдывают стоимость end-to-end tests?

## Варианты формулировки и происхождение

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Тестирование — `00:26:56–00:27:43`|Adcamp, тестирование]].
- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Testing и mocks — `00:21:26–00:22:21`|MERLION, testing и mocks]].

- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Database indexes, testing и performance — `00:14:50–00:19:01`|Database indexes, testing и performance — `00:14:50–00:19:01`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Тестирование — `00:59:34–01:11:20`|Тестирование — `00:59:34–01:11:20`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, глава 17, проверено 2026-07-18.
- [Test Sizes](https://testing.googleblog.com/2010/12/test-sizes.html) — Google Testing Blog, модель Small/Medium/Large, проверено 2026-07-18.
- [How Much Testing is Enough?](https://testing.googleblog.com/2021/06/how-much-testing-is-enough.html) — Google Testing Blog, 2021, risk и coverage в test strategy, проверено 2026-07-18.
- [Secure Software Development Framework 1.1](https://doi.org/10.6028/NIST.SP.800-218) — NIST, SP 800-218 version 1.1, practice PW.8, проверено 2026-07-18.
- [Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/) — OWASP Foundation, ASVS 5.0.0, проверено 2026-07-18.
