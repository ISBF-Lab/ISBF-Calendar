# ISBF Calendar

Discourse 插件，提供 `/isbf/calendar`、`/isbf/workbench` 和仅当前用户可访问的个人日程 API。界面由 `themes/isbf-campus-feed` 实现。前端日历按个人手动行程与已添加的官方活动分类，不再查询原生社区活动；原生记录和话题不删除。

## 官方时间项

依赖 `discourse-academy-roles` 的 `academy_roles_enabled`、`academy_official_category` 和 `academy_official_group`。官方发布者在分类首帖的发布或编辑窗口填写时间项；编辑仍遵守该首帖的 Guardian 权限。官方组须具有相应的发帖和编辑权限。

每条消息最多 20 个时间项，名称最多 120 字。时间项可以是活动或截止日期，使用北京时间 `Asia/Shanghai`。活动可以省略结束时间，此时存储为一个时间点。仅日期的截止项表示整天，不推断具体截止时刻；全天日期范围的结束时刻为次日北京时间零点，且不包含该时刻。

时间项通过 `isbf_official_calendar_items` JSON 字符串与首帖一同提交，包含 `title`、`schedule_kind`（`event` / `deadline`）、`starts_at`、`ends_at`、`all_day`。时间必须为带时区的 ISO 8601 字符串，数据库存 UTC。编辑已有时间项必须附带它的 `id` 和 `revision`。保留 ID 表示修改或排序，省略该项表示取消，新项不传 ID；已取消的 ID 不可复用。仅排序和普通正文编辑不会产生新的源版本。

从 0.3.0 起，活动支持可选的 `location`（最多 255 字）、`organizer`（最多 120 字）和报名截止项。报名截止仍是一条可单独导入日历的 `deadline` 时间项；活动请求的 `registration_deadline_index` 指向同一数组中该截止项的零基下标，设为 `null` 可解除关联。关联必须属于同一消息，一个截止项最多关联一个活动。响应使用稳定的 `registration_deadline_id`。活动和报名截止分别计入 20 个时间项上限。

旧客户端省略新字段时保留已有地点、主办方和仍在请求数组中的截止关联；传入空值可以清除。历史活动不自动匹配历史截止日期。地点、主办方和关联记录在首帖修订前后数据中。从0.5.0起，地点纳入导入快照及版本确认；地点变化会升版并通知，主办方及关联单独变化仍不升版。

首帖详情提供逐项添加按钮；消息流只显示摘要。每个用户与源时间项之间有唯一索引，重复请求返回已有记录。导入项保存当时的信息，私人备注最多 2000 字，仅本人可编辑和删除；官方名称、类型、时间和地点不可直接修改。

官方变更通过提交后的后台任务发送站内通知，并在日历顶部跨月份列出待确认项。接受更新才替换个人快照，私人备注保留；保留原信息仅忽略当前源版本，之后的新版本仍提示。删除时间项或消息会标记取消，保留个人记录和备注。隐藏、私有化或失去访问权限的消息不会通过日历或通知暴露新的信息。

## API

- `GET /isbf/api/entries.json?from=<ISO8601>&to=<ISO8601>`：当前用户在时间范围内的行程，范围最多 62 天。
- `GET /isbf/api/entries/:id.json`：本人单条行程，可用于通知跨月定位。
- `POST /isbf/api/entries.json`：创建手动行程，返回 201。
- `PATCH /isbf/api/entries/:id.json`：修改手动行程，或仅更新官方导入项的 `note`。
- `DELETE /isbf/api/entries/:id.json`：删除本人行程。
- `POST /isbf/api/official-items/:id/add.json`：传入 `revision`，新增返回 201，已添加返回 200。
- `GET /isbf/api/entry-updates.json`：所有月份的待确认变更。
- `POST /isbf/api/entries/:id/accept-update.json`：传入 `revision`，返回更新后的行程。
- `POST /isbf/api/entries/:id/dismiss-update.json`：传入 `revision`，保留当前信息并忽略该源版本，成功返回 204。

手动行程写入参数放在 `entry` 对象中：`title`、`starts_at`、`ends_at`、`all_day`、`note`、可选的 `location`（去首尾空白，最多255字符）。省略地点保留已有值，空字符串或null清空；非字符串拒绝。添加或确认时源版本过期返回 409；客户端刷新最新信息，重新由用户决定。用户不能访问其他人的行程。

行程响应包含 `source_item_id`、`accepted_revision`、`needs_update`、`cancelled`、`source_unavailable`、`source_url` 和 `latest_source`。后者仅在当前用户仍可访问源消息时包含最新内容；无法访问的取消项仅暴露取消状态与版本。

不支持重复日程、到点提醒或自然语言识别。

## Apple 日历私人订阅

`GET /isbf/api/calendar.ics` 为当前已认证用户导出私人订阅，复用 Discourse 原生 `register_calendar_subscription_feed`、`add_user_api_key_scope`、`add_api_parameter_route` 和 `CalendarSubscriptionsController`，不创建新密钥系统或数据库表。需要支持这些原生接口的 Core；站点元数据 `site.isbf_calendar.subscription_feed` 为 `isbf_personal` 时前端才展示入口。旧 Core 未注册时该字段为 `null`。

前端使用原生 `GET/POST/DELETE /calendar-subscriptions.json` 查询、生成和撤销订阅，使用返回的 `urls.isbf_personal`。主题负责日历页入口及 `calendar-subscriptions-feeds` outlet 的原生 `CalendarSubscriptionUrl` 行；插件没有新增前端资源。生成链接会重新生成当前用户所有原生日历订阅的共享密钥，撤销也会同时停用书签、活动等其他原生订阅。已有链接无法再次取回，前端应先查询状态并在重新生成或撤销前说明影响，禁止自动重新生成。

链接含私人访问密钥，持有者可读取该用户的日程与私人备注。密钥权限 `isbf-calendar:personal_calendar` 仅匹配此 GET ICS 动作；不支持 JSON、写入或选择其他用户。请求使用原生 `user_api_key` 查询参数鉴权，返回 `Cache-Control: private, no-store`，并过滤该参数的 Rails 日志。反向代理或外部访问日志也须沿用原生日历订阅的敏感查询参数过滤策略，不保存完整订阅 URL。

订阅范围为每次请求时过去一年到未来两年，包含与窗口重叠的全部本人记录，不按条数截断；范围同时写在日历描述。窗口之外和本人删除的记录会从后续完整 feed 中消失，客户端移除行为与刷新时机取决于 Apple 日历。此为服务器到 Apple 的单向、只读订阅，刷新由 Apple 控制，不保证立即更新；Apple 中的修改不会写回本站。

个人和官方导入项均导出本人已保存的名称、时间、非空地点及私人备注，接受官方更新后才改变快照。不导出源消息正文、未确认版本的地点或主办方。来源 URL 仅在当前用户仍可见来源话题与首帖时提供。官方取消或话题删除后保留原快照与备注，并输出 `STATUS:CANCELLED`；取消状态允许在失去来源权限后继续反映，绝不附带新源内容。创建时间来自个人记录；修改时间和 DTSTAMP 通常来自个人记录，取消时取个人和源记录修改时间的较晚值，避免已取消状态被客户端忽略。

UID 固定使用站点主机名、所有者 ID 与记录 ID，不包含访问密钥或当前时间。时间点使用 UTC；零时长截止项不补造结束时间。全天项使用排除结束日的 DATE：手动项沿用 UTC 日期约定，官方快照按其既有北京时间零点存储约定还原日期。文本复用原生 `IcalEncoder`，补充孤立 CR 处理，并以 CRLF 和不拆分 UTF-8 字符的 75 字节折行输出。

## 验证与部署

使用独立数据库运行插件测试，不重置运行中的开发站点：

完整测试套件沿用线上 `discourse-academy-roles` 的身份与 Guardian 权限契约，运行时须同时加载该依赖（包括其 SiteSetting 与 moderator 权限扩展）；仅装 stock Core 不能验证这些已有官方发布测试。该依赖内置于本站 Core fork `ISBF-Lab/ISBFweb`。新增订阅回归位于 `spec/requests/isbf_calendar/subscriptions_controller_spec.rb` 和 `spec/lib/isbf_calendar/subscription_feed_spec.rb`。

CI 使用官方 `discourse/discourse_test:slim` 容器和原生 Core 测试数据库启动脚本，分别运行独立订阅适配测试及完整 Calendar specs。完整测试加载 `test/dependencies` 内未经修改的生产身份插件快照，来源为本站已合并提交 `132cc95d043db01251eedf9c93b3927cd5ffee91`，并在复制前逐文件验证 SHA-256。该快照仅用于测试，发布包必须排除 `test/`；不会替换生产身份插件。这样无需跨私有仓库凭据，也不改变仓库禁用部署密钥的设置。测试基于上游 Core，生产固定版本兼容性仍需发布前后实际加载与路由验收；不将 CI 视为真机验证。Ruby job 另执行语法检查。

```sh
RAILS_ENV=test LOAD_PLUGINS=1 RAILS_DB=isbf_calendar_test bin/rake db:create db:migrate
RAILS_ENV=test LOAD_PLUGINS=1 RAILS_DB=isbf_calendar_test bin/rspec plugins/isbf-calendar/spec
```

迁移 `20261006101910_add_official_calendar_items.rb` 为增量变更，旧手动行程无需回填。`20261006160545_add_official_activity_details.rb` 增加活动地点、主办方和截止关联，旧记录的文本字段为空、关联为空。先部署插件并运行迁移，再部署主题界面。已有历史官方消息在编辑首帖时补充时间项即可。

线上主题 ID 4 的更新必须先导出新备份并比对当前字段，仅同步本功能涉及的字段或增量补丁，保留其设置、组件和其他更新；不要导入旧的完整主题覆盖。确认 JavaScript、测试和明暗主题样式均编译通过，再验证首帖发布、逐项添加、改期通知、确认与保留、取消，以及原有手动日程和社区活动。

## 0.5.0 地点兼容

迁移仅在已有行程表增加可空的255字符地点列，不新增表、不改写ID、时间或版本。旧null官方地点仅在来源仍可见且版本等于已确认版本时只读兼容；否则返回空字符串，不从隐藏或权限受限来源补新信息。新导入和接受更新保存地点快照，订阅 LOCATION 与接口使用相同的来源判断及原生文本转义。回滚保留该增量列，避免丢弃新地点。
