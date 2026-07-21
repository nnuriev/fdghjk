---
aliases:
  - "Теоретический вопрос: Rate limiting и quotas"
tags:
  - область/бэкенд
  - тема/http
  - тема/безопасность
  - тема/устойчивость
  - тип/вопрос
статус: проверено
---

# Rate limiting и quotas

## Вопрос

Как работает «Rate limiting и quotas» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Rate limit ограничивает скорость поступления работы за короткий интервал. Quota ограничивает накопленное потребление за более длинный период или выделяет клиенту конечный объём ресурса. Concurrency limit решает третью задачу: сколько дорогих операций одновременно удерживают ресурсы.

Корректный limiter сначала определяет identity, scope и стоимость запроса, затем атомарно принимает либо отклоняет его. Token bucket допускает контролируемый burst и удерживает среднюю скорость через refill. `429 Too Many Requests` сообщает о превышении клиентского ограничения; временная нехватка capacity самого сервиса ближе к `503 Service Unavailable` и [[40 Распределённые системы/Load shedding|load shedding]].

Abuse prevention шире. Атакующий может распределить допустимые действия по IP, аккаунтам и времени, не превысив ни один простой rate limit. Поэтому защита связывает многоуровневые limits с бизнес-инвариантами, сигналами риска, step-up проверкой и расследуемым audit trail. Limiter принимает детерминированное решение о бюджете; risk engine оценивает поведение и не должен незаметно подменять authorization.

Полный разбор: [[20 Бэкенд/Rate limiting и quotas|Rate limiting и quotas]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/03 Каналы, время и паттерны#Rate limiter|Rate limiter]] — сравнение fixed/sliding window, leaky и token bucket.
- [[CurseHunter/7091/03 Контроль нагрузки#3. Rate limiting algorithms|3. Rate limiting algorithms]] — сравнение token bucket, leaky bucket, fixed и sliding window.
- [[CurseHunter/7091/03 Контроль нагрузки#4. Distributed limiter: точность против доступности|4. Distributed limiter: точность против доступности]] — вопрос о global quota, overshoot и fail-open/fail-closed.
- «Проектирование rate limiter и проектирование ratelimiter-а — нужно исходное условие; это семантический дубль в списке. База: Проектирование rate limiter, Rate limiting и quotas.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].
- «Защита от автоматизированных заказов — нужно исходное условие; база: Моделирование угроз, Rate limiting и quotas, Replay attacks.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [RFC 6585: Additional HTTP Status Codes](https://datatracker.ietf.org/doc/html/rfc6585) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RateLimit header fields for HTTP](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers-11) — IETF HTTPAPI Working Group, Internet-Draft `-11`, май 2026, срок действия до 2026-11-24, проверено 2026-07-18.
- [Request throttling for the Amazon EC2 API](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html) — Amazon Web Services, официальная документация EC2 API, проверено 2026-07-18.
- [Local rate limit](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/local_rate_limit_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [NIST SP 800-63B-4: Authentication and Authenticator Management](https://pages.nist.gov/800-63-4/sp800-63b.html) — NIST, SP 800-63B-4, июль 2025, проверено 2026-07-18.
- [OWASP Automated Threats to Web Applications](https://owasp.org/www-project-automated-threats-to-web-applications/) — OWASP Foundation, vendor-neutral taxonomy OAT-001–OAT-021, проверено 2026-07-18.
- [Bot Management and Anti-Automation Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Bot_Management_and_Anti-Automation_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная редакция на 2026-07-18, проверено 2026-07-18.
