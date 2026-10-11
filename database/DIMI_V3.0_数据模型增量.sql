-- ============================================================================
-- DIMI · 围城 V3.0 数据模型增量
-- 依据：《DIMI围城_深度洞察与差异化升级方案_V3.md》§14.1
--       《DIMI围城_法律合规与护城河深化_V3.1.md》A2 / A3 / A8
--
-- 三条不可谈判的红线（V3.1 A8，凡触碰默认"不做"，除非专项法律评审）：
--   1. 人脸：不做识别检索；不做唯一验证；特征即用即删；到量（10 万人）即备案。
--   2. 未成年人：14 周岁以下不予注册；14–18 周岁强制未成年人模式；营销零触达。
--   3. 资金：V3.x 期间平台不碰支付、不经手资金，聚会 AA 只记账不动钱。
--
-- 存储最小化原则：人脸特征不落库（核验在端侧/专用服务完成，即用即删），
-- 本库仅留存"认领/核验结果"记录；验证证据源文件核验后 30 天内删除。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 验证体系（V3.0 §3.1）：分层验证 V0–V3，替换原 is_verified 布尔字段
-- ----------------------------------------------------------------------------
ALTER TABLE education_experiences
  ADD COLUMN verification_level  tinyint      NOT NULL DEFAULT 0
    COMMENT '验证等级：V0自述 / V1同窗互证 / V2证据验证 / V3组织背书',
  ADD COLUMN verified_at         datetime     NULL
    COMMENT '首次达到当前等级的验证时间',
  ADD COLUMN verification_source varchar(32)  NULL
    COMMENT '验证来源：peer_review 互证 / document 证据 / org_roster 组织名册';

-- 新填经历 7 天内检索曝光降权 0.5x（防批量伪造窗口期作恶），由检索层读取
-- education_experiences.created_at 计算，不另设字段。

-- 验证证据（V2 证据验证）
-- 合规：证件仅用于核验，不做人脸比对、不用于检索；
--       核验完成后 30 天内删除源文件（source_file_deleted_at 记录删除时间）；
--       核验记录（不含图像）留存用于审计。
CREATE TABLE verification_evidences (
  id                     bigint unsigned NOT NULL AUTO_INCREMENT,
  user_id                bigint unsigned NOT NULL,
  education_id           bigint unsigned NOT NULL,
  type                   varchar(16)     NOT NULL COMMENT 'diploma 毕业证 / student_card 学生证 / class_photo 毕业照',
  ocr_result             json            NULL COMMENT 'OCR 核验结果（校名+年份一致性）',
  status                 varchar(16)     NOT NULL DEFAULT 'pending'
                         COMMENT 'pending 待审 / approved 通过 / rejected 驳回',
  audited_by             bigint unsigned NULL COMMENT '人审兜底审核员',
  source_file_deleted_at datetime        NULL COMMENT '源文件删除时间（核验后 30 天内必须落值）',
  created_at             datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user (user_id),
  KEY idx_education (education_id),
  KEY idx_status (status)
) ENGINE=InnoDB COMMENT='经历验证证据（V2）；源文件即用即删，仅存核验记录';

-- ----------------------------------------------------------------------------
-- 云班级（V3.0 §6 + V3.1 A2）
-- 合规要点：
--   - 不做人脸识别检索（不提供"上传照片找人"），人脸检测仅用于分割标注；
--   - 人脸比对仅用于"本人认领"一对一核验，且为三条平权路径之一（非唯一验证）；
--   - 人脸特征不入库、即用即删，photo_claims 仅存核验结果；
--   - 默认仅本班 V1+ 成员可见，永不公开、不进推荐 Feed、不进搜索结果；
--   - 仅支持毕业 ≥3 年的历史照片（应用层硬校验，涉及在读未成年人一律不入库）；
--   - 人脸信息存储量达 10 万人起 30 个工作日内向省级以上网信部门备案
--     （运维侧建立存储量监控，达阈值自动触发备案流程）。
-- ----------------------------------------------------------------------------
CREATE TABLE class_photos (
  id            bigint unsigned NOT NULL AUTO_INCREMENT,
  school_id     bigint unsigned NOT NULL,
  enroll_year   smallint       NOT NULL COMMENT '入学年份（届）',
  class_norm    varchar(32)    NOT NULL COMMENT '归一化班级名，如 6-2',
  uploader_id   bigint unsigned NOT NULL,
  original_url  varchar(512)   NOT NULL,
  restored_url  varchar(512)   NULL COMMENT 'AI 修复产物（自动添加"AI修复"显式水印+元数据隐式标识）',
  face_grid     json           NULL COMMENT '人脸分割网格坐标（仅位置，不含特征）',
  visibility    varchar(16)    NOT NULL DEFAULT 'class_verified'
                COMMENT 'class_verified 仅本班V1+（默认） / grade 同届；永不 public',
  status        varchar(16)    NOT NULL DEFAULT 'active'
                COMMENT 'active / taken_down 已撤下 / reviewing 审核中',
  created_at    datetime       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_unit_photo (school_id, enroll_year, class_norm, original_url(191)),
  KEY idx_unit (school_id, enroll_year, class_norm),
  KEY idx_uploader (uploader_id)
) ENGINE=InnoDB COMMENT='云班级毕业照；上传者须承诺"我是本班成员，有权分享此照片"';

CREATE TABLE photo_annotations (
  id            bigint unsigned NOT NULL AUTO_INCREMENT,
  photo_id      bigint unsigned NOT NULL,
  grid_index    smallint       NOT NULL COMMENT '人脸网格序号',
  annotated_name varchar(32)   NOT NULL,
  annotated_by  bigint unsigned NOT NULL COMMENT '标注人',
  claimed_by    bigint unsigned NULL COMMENT '认领人 user_id',
  claim_status  varchar(16)    NOT NULL DEFAULT 'unclaimed'
                COMMENT 'unclaimed 未认领 / claiming 认领中 / claimed 已认领 / blurred 已模糊 / hidden 纠错隐藏',
  correct_count smallint       NOT NULL DEFAULT 0
                COMMENT '纠错次数；≥2 人纠错自动隐藏并通知上传者（V3.1 A2.4 名誉权边界）',
  created_at    datetime       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_photo_grid (photo_id, grid_index),
  KEY idx_name (annotated_name)
) ENGINE=InnoDB COMMENT='毕业照人脸网格标注（"点亮名字"的可视化）';

-- 认领核验记录：仅留存"认领结果"，不含任何人脸特征数据（V3.1 A2.2 存储最小化）
CREATE TABLE photo_claims (
  id            bigint unsigned NOT NULL AUTO_INCREMENT,
  photo_id      bigint unsigned NOT NULL,
  grid_index    smallint       NOT NULL,
  claimant_id   bigint unsigned NOT NULL,
  method        varchar(16)    NOT NULL
                COMMENT 'face 人脸比对(自愿·单独同意) / peer 同窗互证(≥2名已验证同班成员) / document 凭证人工核验；三路径平权，人脸非唯一验证',
  verify_result varchar(16)    NOT NULL COMMENT 'passed / rejected / pending_review',
  created_at    datetime       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_photo (photo_id, grid_index),
  KEY idx_claimant (claimant_id)
) ENGINE=InnoDB COMMENT='认领核验结果记录（不存人脸特征，特征即用即删）';

-- 撤下/模糊申请（V3.1 A2.4）：照片中任何人无需注册、无需证明身份关系即可申请，SLA 24h
CREATE TABLE photo_takedown_requests (
  id          bigint unsigned NOT NULL AUTO_INCREMENT,
  photo_id    bigint unsigned NOT NULL,
  grid_index  smallint       NULL COMMENT 'NULL 表示申请撤下整张照片',
  action      varchar(16)    NOT NULL COMMENT 'blur_me 模糊本人 / takedown 撤下整照',
  contact     varchar(64)    NULL COMMENT '可选回执联系方式',
  status      varchar(16)    NOT NULL DEFAULT 'pending' COMMENT 'pending / done / rejected',
  created_at  datetime       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  handled_at  datetime       NULL,
  PRIMARY KEY (id),
  KEY idx_photo (photo_id),
  KEY idx_status_sla (status, created_at)
) ENGINE=InnoDB COMMENT='免注册 H5 撤下通道；SLA 24h，status+created_at 索引用于超时监控';

-- ----------------------------------------------------------------------------
-- 聚会系统（V3.0 §8.2）
-- 资金红线：AA 仅记账不动钱，本库不存任何支付流水。
-- ----------------------------------------------------------------------------
CREATE TABLE events (
  id             bigint unsigned NOT NULL AUTO_INCREMENT,
  creator_id     bigint unsigned NOT NULL,
  unit_type      varchar(16)     NOT NULL COMMENT 'class 班级 / hometown 同乡 / group 群组',
  unit_id        varchar(64)     NOT NULL COMMENT '单元标识（school_id+enroll_year+class_norm 或 region_id 或 group_id）',
  title          varchar(64)     NOT NULL,
  event_time     datetime        NOT NULL,
  location_poi   varchar(128)    NULL,
  signup_deadline datetime       NULL,
  aa_amount_cent int unsigned    NULL COMMENT 'AA 记账金额（分），仅记账不动钱',
  status         varchar(16)     NOT NULL DEFAULT 'open' COMMENT 'open / closed / canceled / finished',
  created_at     datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_unit (unit_type, unit_id),
  KEY idx_creator (creator_id),
  KEY idx_time (event_time)
) ENGINE=InnoDB COMMENT='聚会（C 端轻量版，组织号活动系统下放）';

CREATE TABLE event_signups (
  event_id   bigint unsigned NOT NULL,
  user_id    bigint unsigned NOT NULL,
  status     varchar(16)     NOT NULL DEFAULT 'signup' COMMENT 'signup 报名 / leave 请假 / waitlist 候补',
  created_at datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (event_id, user_id)
) ENGINE=InnoDB COMMENT='聚会报名接龙';

CREATE TABLE event_albums (
  id                    bigint unsigned NOT NULL AUTO_INCREMENT,
  event_id              bigint unsigned NOT NULL,
  photo_url             varchar(512)    NOT NULL,
  linked_class_photo_id bigint unsigned NULL COMMENT '关联云班级毕业照，沉淀为班级资产',
  created_at            datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_event (event_id)
) ENGINE=InnoDB COMMENT='聚会相册，自动聚合反哺云班级';

-- ----------------------------------------------------------------------------
-- 场景日历（V3.0 §8.1）
-- 系统预生成 + 触发时经通知决策表过滤；人生历/关系历每月合计 ≤4 条 Push。
-- ----------------------------------------------------------------------------
CREATE TABLE calendar_events (
  id           bigint unsigned NOT NULL AUTO_INCREMENT,
  user_id      bigint unsigned NOT NULL,
  type         varchar(16)     NOT NULL
               COMMENT 'life 人生历 / relationship 关系历 / system 系统历 / regional 地域历',
  ref_id       varchar(64)     NULL COMMENT '关联对象（经历/好友关系/班级单元）',
  trigger_date date            NOT NULL,
  payload      json            NULL COMMENT '卡片内容（纪念文案、聚合照片引用等）',
  pushed_at    datetime        NULL COMMENT 'NULL=未推送；推送前必经通知决策表与月频控',
  created_at   datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user_date (user_id, trigger_date),
  KEY idx_pending_push (type, trigger_date, pushed_at)
) ENGINE=InnoDB COMMENT='场景日历；唤醒的本质是精准，不是频率';

-- ----------------------------------------------------------------------------
-- 代际协助关系（V3.0 §10.3）
-- 边界：协助者可填写/修改经历、管理隐私设置；
--       不能读消息、不能看朋友圈、不能代为聊天；
--       敏感操作（加好友通过、联系方式交换）仍需被协助人本人手机确认；
--       所有协助行为写入 audit_logs，被协助端可见；任一方可单方随时解除。
-- ----------------------------------------------------------------------------
CREATE TABLE assist_relations (
  id               bigint unsigned NOT NULL AUTO_INCREMENT,
  assisted_user_id bigint unsigned NOT NULL COMMENT '被协助人（父母）',
  assistant_user_id bigint unsigned NOT NULL COMMENT '协助者（子女）',
  scope            json            NOT NULL COMMENT '可代办项白名单，如 ["edit_education","manage_privacy"]',
  status           varchar(16)     NOT NULL DEFAULT 'pending' COMMENT 'pending 待确认 / active 生效 / revoked 已解除',
  confirmed_at     datetime        NULL COMMENT '被协助人本人手机一键确认时间',
  revoked_at       datetime        NULL,
  created_at       datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_pair_active (assisted_user_id, assistant_user_id, status),
  KEY idx_assistant (assistant_user_id)
) ENGINE=InnoDB COMMENT='子女协助模式授权链路；协助的是数字能力，不是社交替身';

-- ----------------------------------------------------------------------------
-- 会员体系 DIMI+（V3.0 §11）
-- 总纲：只卖"自己能力的增强"，不卖"他人信息的访问权"；
--       会员不获得检索豁免、隐私突破、推荐加权；明确不做隐身访问。
-- ----------------------------------------------------------------------------
CREATE TABLE subscriptions (
  id         bigint unsigned NOT NULL AUTO_INCREMENT,
  user_id    bigint unsigned NOT NULL,
  plan       varchar(32)     NOT NULL COMMENT 'monthly 连续包月 / yearly 包年 / one_time_restore 单次照片修复',
  started_at datetime        NOT NULL,
  expires_at datetime        NULL COMMENT '单次产品为 NULL',
  source     varchar(16)     NOT NULL DEFAULT 'self' COMMENT 'self 自购 / org_group 组织团购 / compensation 补偿',
  status     varchar(16)     NOT NULL DEFAULT 'active' COMMENT 'active / expired / refunded',
  created_at datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_user_status (user_id, status),
  KEY idx_expire (expires_at)
) ENGINE=InnoDB COMMENT='会员订阅；渗透率健康区间 3%–8%，>10% 触发免费体验审计';

CREATE TABLE entitlements (
  user_id     bigint unsigned NOT NULL,
  feature     varchar(32)     NOT NULL
              COMMENT 'msg_roam 消息漫游 / profile_views 谁看过我 / search_depth 检索深度 / photo_restore 照片修复 / lifemap_assets 人生地图物料 / event_quota 聚会发起 / support_priority 优先客服',
  quota       int             NULL COMMENT '额度；NULL=不限量',
  reset_cycle varchar(16)     NULL COMMENT 'monthly 月度重置 / yearly / NULL 不重置',
  updated_at  datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, feature)
) ENGINE=InnoDB COMMENT='会员权益额度（如照片修复月度张数）';

-- ----------------------------------------------------------------------------
-- 推荐标签（V3.1 A4 算法合规）
-- 《互联网信息服务算法推荐管理规定》第 15 条：用户可查看/选择/修改/删除
-- 系统给自己打的标签；删除后该标签不再用于推荐。
-- ----------------------------------------------------------------------------
CREATE TABLE recommendation_tags (
  id         bigint unsigned NOT NULL AUTO_INCREMENT,
  user_id    bigint unsigned NOT NULL,
  tag        varchar(64)     NOT NULL COMMENT '如"90年代小学生""豫籍在杭"',
  source     varchar(16)     NOT NULL DEFAULT 'system' COMMENT 'system 系统标注 / user 用户自选',
  deleted_at datetime        NULL COMMENT '用户删除时间；删除后推荐侧硬过滤',
  created_at datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_user_tag (user_id, tag),
  KEY idx_user_active (user_id, deleted_at)
) ENGINE=InnoDB COMMENT='我的推荐标签；此功能同时是信任资产，应主动宣传';

-- ----------------------------------------------------------------------------
-- 班级群聊（V0.9）：班级单元（school_id + enroll_year + class_name_norm）一一对应
-- 一个群会话（conversations.conv_type='group'）。入群依据=同班级单元归属
-- （education_experiences 记录），群成员不要求互为好友；
-- 群成员复用 conversation_members（已读位点/置顶/免打扰），不另设成员表。
-- ----------------------------------------------------------------------------
CREATE TABLE class_groups (
  group_id        bigint unsigned NOT NULL AUTO_INCREMENT,
  conv_id         bigint unsigned NOT NULL COMMENT '对应 conversations.conv_id（conv_type=group）',
  school_id       bigint unsigned NOT NULL,
  enroll_year     int             NOT NULL,
  class_name_norm varchar(32)     NOT NULL COMMENT '规范化班级名，与 education_experiences.class_name_norm 一致',
  announcement    varchar(200)    NOT NULL DEFAULT '' COMMENT '群公告，仅群主可改',
  created_by      bigint unsigned NULL COMMENT '群主；退群时顺延给最早加入者，群空则保留',
  created_at      datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (group_id),
  UNIQUE KEY uk_class_unit (school_id, enroll_year, class_name_norm),
  KEY idx_conv (conv_id)
) ENGINE=InnoDB COMMENT='班级群：一个班级单元一个群，入群依据=同单元教育经历';


-- ----------------------------------------------------------------------------
-- 觅豆（P0 纯赠送体系，《DIMI围城_虚拟币与打赏体系设计_V1.md》§1.3/§6/§8.2）
-- 红线约束（V3.1 A8：平台不碰支付、不经手资金）：币只能任务/活跃获得，
-- 无充值、无提现、不产生任何现金价值；红包退回的是币不是钱。
-- 表结构与 P1+ 真金方案同构：充值单号/金额分/分账等字段届时 ALTER 追加，
-- 本层不改既有列。服务端落地时转写为 SQLite 并入 db.js 启动建表段。
-- ----------------------------------------------------------------------------

-- 消费币账户：balance 为缓存，以 coin_transactions 流水重算为准
CREATE TABLE coin_accounts (
  user_id      bigint unsigned NOT NULL,
  balance      int             NOT NULL DEFAULT 0 COMMENT '觅豆余额（缓存）',
  total_earned int             NOT NULL DEFAULT 0,
  total_spent  int             NOT NULL DEFAULT 0,
  updated_at   datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id)
) ENGINE=InnoDB COMMENT='觅豆账户（P0 纯赠送：只进任务赠送，不可购买）';

-- 币账流水：收入天然幂等（uk_entry 撞键即重放），支出按条件更新防透支
CREATE TABLE coin_transactions (
  id            bigint unsigned NOT NULL AUTO_INCREMENT,
  biz_type      varchar(32)     NOT NULL
                COMMENT 'grant_task 任务赠送 / red_packet_send / red_packet_claim / red_packet_refund / gift_send / gift_recv',
  biz_id        varchar(64)     NOT NULL COMMENT '对侧单据 id（packet_id / order_id / task_code:period_key）',
  user_id       bigint unsigned NOT NULL,
  direction     varchar(8)      NOT NULL COMMENT 'in / out',
  amount        int             NOT NULL COMMENT '觅豆，恒正',
  balance_after int             NOT NULL,
  remark        varchar(64)     NULL,
  created_at    datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_entry (biz_type, biz_id, user_id, direction),
  KEY idx_user (user_id, created_at)
) ENGINE=InnoDB COMMENT='觅豆流水：同一单据同一方向只入账一次';

CREATE TABLE red_packets (
  packet_id      varchar(32)     NOT NULL COMMENT 'RP+随机串',
  conv_id        bigint unsigned NOT NULL COMMENT '会话（班级群或好友单聊）',
  msg_id         bigint unsigned NULL COMMENT '红包消息卡 msg_id（msg_type=red_packet）',
  sender_id      bigint unsigned NOT NULL,
  type           varchar(16)     NOT NULL COMMENT 'luck 拼手气 / normal 普通（私聊固定 normal 1 份）',
  total_amount   int             NOT NULL COMMENT '总觅豆',
  count          int             NOT NULL,
  claimed_amount int             NOT NULL DEFAULT 0,
  claimed_count  int             NOT NULL DEFAULT 0,
  greeting       varchar(20)     NULL,
  status         varchar(16)     NOT NULL DEFAULT 'active' COMMENT 'active / finished / expired（只前进）',
  expire_at      datetime        NOT NULL COMMENT '发出 +24h，未领完原路退回币账户',
  created_at     datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (packet_id),
  KEY idx_expire (status, expire_at)
) ENGINE=InnoDB COMMENT='红包：24h 未领完剩余原路退回币账户（退币不退钱）';

CREATE TABLE red_packet_claims (
  id         bigint unsigned NOT NULL AUTO_INCREMENT,
  packet_id  varchar(32)     NOT NULL,
  user_id    bigint unsigned NOT NULL,
  amount     int             NOT NULL,
  is_best    tinyint         NOT NULL DEFAULT 0 COMMENT '手气最佳（拼手气领完后结算）',
  created_at datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_packet_user (packet_id, user_id),
  KEY idx_packet (packet_id)
) ENGINE=InnoDB COMMENT='红包领取记录：一人一份，天然防重';

-- 打赏单（P0：纯心意，币转移不产生现金收益；P1+ 分成/冷静期字段届时 ALTER 追加）
CREATE TABLE gift_orders (
  order_id    varchar(32)     NOT NULL COMMENT 'G+随机串',
  from_user   bigint unsigned NOT NULL,
  to_user     bigint unsigned NOT NULL,
  moment_id   bigint unsigned NULL COMMENT '打赏挂在动态上（指向内容而非个人，防秀场化）',
  coin_amount int             NOT NULL COMMENT '固定面额 1/5/10/52/100 觅豆',
  status      varchar(16)     NOT NULL DEFAULT 'confirmed',
  created_at  datetime        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (order_id),
  KEY idx_moment (moment_id),
  KEY idx_to_user (to_user, created_at)
) ENGINE=InnoDB COMMENT='动态打赏单（P0 无现金价值；收益字段属 P1+ 经法务释义后追加）';
