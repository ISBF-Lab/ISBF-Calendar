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
- `PATCH /isbf/api/entries/:id.json`：修改手动行程，或更新官方导入项的私人备注和提醒。
- `DELETE /isbf/api/entries/:id.json`：删除本人行程。
- `POST /isbf/api/official-items/:id/add.json`：传入 `revision`，新增返回 201，已添加返回 200。
- `GET /isbf/api/entry-updates.json`：所有月份的待确认变更。
- `POST /isbf/api/entries/:id/accept-update.json`：传入 `revision`，返回更新后的行程。
- `POST /isbf/api/entries/:id/dismiss-update.json`：传入 `revision`，保留当前信息并忽略该源版本，成功返回 204。

手动行程写入参数放在 `entry` 对象中：`title`、`starts_at`、`ends_at`、`all_day`、`note`、可选的 `location`（去首尾空白，最多255字符）。省略地点保留已有值，空字符串或null清空；非字符串拒绝。添加或确认时源版本过期返回 409；客户端刷新最新信息，重新由用户决定。用户不能访问其他人的行程。

行程响应包含 `source_item_id`、`accepted_revision`、`needs_update`、`cancelled`、`source_unavailable`、`source_url` 和 `latest_source`。后者仅在当前用户仍可访问源消息时包含最新内容；无法访问的取消项仅暴露取消状态与版本。

不支持重复日程或自然语言识别。

## 可选日程提醒（0.6.0）

管理员在 Discourse 原生站点设置中选择一种提醒策略：isbf_calendar_reminders_enabled 默认为 true，可关闭提醒任务与订阅闹铃；isbf_calendar_reminder_delivery_mode 默认为 in_app（站内提醒），另一选项为 subscription_preferred（订阅日历优先，未满足订阅条件时回退站内提醒）。这是一个投递策略，不是两路独立开关。仅对启用、已批准、非暂存且未被停权的日程所有者处理；不会发送邮件，也不调用 PostAlerter 的推送流程。原有官方改期通知保持独立。

每条日程默认 reminder_mode: "none"。定时行程支持 before_5m、before_15m、before_30m、before_1h、before_24h，以已保存开始时刻为锚点。全天行程仅支持 same_day_9am 和 previous_day_9am。个人全天项保留既有 UTC 日期约定，必须提交有效浏览器 IANA reminder_timezone，按该日期当地上午 9 点计算并正确处理夏令时；官方全天项固定按 Asia/Shanghai 的日期和上午 9 点计算，不把时区换算后的前一天当成源日期。

创建或修改手动日程在 entry 中传 reminder_mode、reminder_timezone；添加官方时间项在顶层与 revision 一同传入，提醒与初始快照在同一事务中保存。重复添加返回原记录，不覆盖已有提醒。官方导入项仅允许修改 note 和这两个提醒字段。省略字段保留已有值，none 清除提醒，全天属性改变导致模式不兼容时重置为 none。响应增加 reminder_mode、reminder_timezone、ISO 8601 reminder_at 和 reminder_delivery（in_app / calendar / null）；site.isbf_calendar.reminders 提供 enabled、delivery_mode、timed_modes、all_day_modes。

开始时刻、全天属性或提醒设置变化会生成新的提醒版本并使旧导出证据失效；备注、地点、标题及仅结束时间编辑不重置已处理标记。接受官方更新时沿用相同规则，仅信息更新保留既有提醒状态；保留原信息继续使用旧快照；源项取消、删除、隐藏或当前用户失去来源访问权限时均不发提醒。已过去的提醒允许保存，但不会立即补发。每分钟原生计划任务按待处理提醒索引分批查找；正常延迟最多补发 10 分钟，定时项开始时刻还须在未来，全天提醒须处于相同本地日期。提醒在全局停用期间经过触发时刻，再启用时不追补。通知创建与已处理标记在同一日程行锁和事务内完成，失败回滚后可重试；每个提醒版本只作一次投递决定。

subscription_preferred 仅在**当前提醒版本的 VALARM 已通过当前仍有效、具备 isbf-calendar:personal_calendar scope 的原生 calendar-subscriptions UserApiKey 实际请求导出**后，才在到点时采用 calendar，省略本站通知。仅生成链接、仅浏览器会话下载、其他应用或其他 feed 的密钥均不会建立此证据。撤销、过期、移除 scope、轮换密钥，或修改提醒后尚未重新读取 feed，都会回退站内提醒。订阅导出本身不写数据库；控制器在完整构建并渲染 ICS 后，用日程行锁和提醒版本比对记录导出证据，旧请求不能确认新提醒。不会为了提醒自动生成或轮换订阅密钥。

ICS 在此策略下为每个有效未来提醒输出一个 ACTION:DISPLAY 和经过原生转义的标题 DESCRIPTION。定时行程使用相对开始时刻的标准 TRIGGER（如 -PT5M、-PT24H），对应原先计算的 UTC 提醒时刻；全天行程仍使用 UTC 绝对时刻，保持所选时区及夏令时规则。已通过有效原生密钥确认导出的当前版本闹钟，在到期和任务处理后继续保留于订阅，不因时间流逝自行删除，也不再次建立导出证据或发送站内通知；从未确认导出的过期提醒仍不导出。关闭提醒、取消或来源不可访问时移除闹钟。每个事件输出 SEQUENCE:reminder_generation，同一秒内修改提醒也会推进版本，UID 保持稳定。全局策略变化通过 PluginStore 的版本及时间戳使旧证据失效并推进 LAST-MODIFIED，不新增表；既有订阅密钥和私人快照约定保持一致。

服务器能证明有效订阅密钥读取了包含当前闹铃的 feed，**不能证明 Apple 等客户端已保存、显示或实际响铃**。客户端刷新、日历提醒权限和通知设置由客户端控制。先前下载或缓存的闹铃在客户端下一次刷新前不能由服务器强制撤回；改期、取消、全局策略变化或密钥撤销后，旧客户端缓存仍可能响铃，因此无法承诺设备端绝不重复。calendar 表示本站已选择日历投递通道，不表示设备送达。

迁移 20261025000000_add_reminders_to_isbf_calendar_entries.rb 仅为现有日程表增加提醒列及待处理索引；旧日程保持 none。回滚时先关闭提醒并部署旧代码，保留增量列以免丢失已保存设置；客户端缓存按上述刷新限制处理。新增模型、API、任务和 ICS 规格覆盖模式、DST、官方日期、权限、幂等、事务失败、实际订阅请求、密钥生命周期及旧导出回执。本机缺少完整 Discourse/Ruby 环境时，以 CI 的实际 RSpec 结果为准，静态检查不替代运行或真机提醒验收。

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
