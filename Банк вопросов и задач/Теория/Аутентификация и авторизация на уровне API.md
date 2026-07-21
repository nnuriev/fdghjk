---
aliases:
  - "Теоретический вопрос: Аутентификация и авторизация на уровне API"
tags:
  - область/бэкенд
  - тема/безопасность
  - тип/вопрос
статус: проверено
---

# Аутентификация и авторизация на уровне API

## Вопрос

Как работает «Аутентификация и авторизация на уровне API» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Аутентификация (authentication, AuthN) устанавливает principal и свойства credential. Авторизация (authorization, AuthZ) решает, может ли этот principal выполнить конкретное действие над конкретным ресурсом в данном контексте. Валидный JWT или scope ещё не дают доступ к произвольному объекту: resource server обязан проверить issuer, audience, срок и профиль токена, а затем применить policy к tenant, owner, состоянию ресурса и операции.

Gateway может отсеять отсутствующие и явно невалидные credentials, но окончательное решение должно находиться у владельца данных и инварианта. Политика работает deny-by-default, а запросы к хранилищу с самого начала ограничиваются разрешённой областью. `401` означает отсутствие валидных authentication credentials и требует challenge; `403` — credentials поняты, но доступа недостаточно. Для сокрытия существования ресурса сервер вправе ответить `404`.

Полный разбор: [[20 Бэкенд/Аутентификация и авторизация на уровне API|Аутентификация и авторизация на уровне API]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Сервис сброса паролей — нужно исходное условие; база: Аутентификация и авторизация на уровне API, Управление секретами.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 6750: The OAuth 2.0 Authorization Framework: Bearer Token Usage](https://datatracker.ietf.org/doc/html/rfc6750) — IETF, RFC 6750, октябрь 2012, обновлён RFC 8996 и RFC 9700, проверено 2026-07-18.
- [RFC 8725: JSON Web Token Best Current Practices](https://datatracker.ietf.org/doc/html/rfc8725) — IETF, BCP 225 / RFC 8725, февраль 2020, проверено 2026-07-18.
- [RFC 9068: JWT Profile for OAuth 2.0 Access Tokens](https://datatracker.ietf.org/doc/html/rfc9068) — IETF, RFC 9068, октябрь 2021, проверено 2026-07-18.
- [RFC 7662: OAuth 2.0 Token Introspection](https://datatracker.ietf.org/doc/html/rfc7662) — IETF, RFC 7662, октябрь 2015, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/html/rfc9700) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
- [NIST SP 800-162: Guide to Attribute Based Access Control Definition and Considerations](https://csrc.nist.gov/pubs/sp/800/162/upd2/final) — NIST, SP 800-162 от января 2014 года, обновление 2 от 2019-08-02, проверено 2026-07-18.
