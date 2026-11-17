
--(run this line alone, then connect to the new database:
--psql -U postgres -c "CREATE DATABASE SaigonBiteF3;"   then   \c saigonbitef3)
--CREATE DATABASE SaigonBiteF3;

--Create tables
CREATE TABLE Hub (
    hub_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hub_name            VARCHAR(120) NOT NULL UNIQUE,
    location            VARCHAR(255) NOT NULL,
    latitude            NUMERIC(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude           NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    capacity_limit      INTEGER NOT NULL CHECK (capacity_limit > 0),
    busy_threshold      INTEGER NOT NULL CHECK (busy_threshold > 0),
    reopening_threshold INTEGER NOT NULL CHECK (reopening_threshold >= 0),
    current_load        INTEGER NOT NULL DEFAULT 0,
    load_status         VARCHAR(10) NOT NULL DEFAULT 'OPEN'
                        CHECK (load_status IN ('OPEN','BUSY','CLOSED')),
    max_delivery_km     NUMERIC(5,2) NOT NULL DEFAULT 5.00 CHECK (max_delivery_km > 0),
    CHECK (busy_threshold <= capacity_limit),
    CHECK (reopening_threshold < busy_threshold),
    CHECK (current_load BETWEEN 0 AND capacity_limit)   -- NFR2: never above capacity
);

CREATE TABLE StaffAccount (
    staff_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     VARCHAR(150) NOT NULL,
    email         VARCHAR(254) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role          VARCHAR(14) NOT NULL
                  CHECK (role IN ('KITCHEN_STAFF','SHIPPER','ADMIN','MANAGER')),
    hub_id        BIGINT REFERENCES Hub(hub_id),
    status        VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CHECK (role <> 'KITCHEN_STAFF' OR hub_id IS NOT NULL)   -- A-08: one hub per kitchen account
);

CREATE TABLE Customer (
    customer_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_type VARCHAR(10) NOT NULL CHECK (customer_type IN ('LOCAL','TOURIST')),
    full_name     VARCHAR(150) NOT NULL,
    phone         VARCHAR(30)  UNIQUE,
    email         VARCHAR(254) UNIQUE,
    passport_ref  VARCHAR(80)  UNIQUE,          -- reference only, never written to logs (NFR4)
    password_hash VARCHAR(255) NOT NULL,
    status        VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        (customer_type = 'LOCAL'   AND phone IS NOT NULL) OR
        (customer_type = 'TOURIST' AND email IS NOT NULL AND passport_ref IS NOT NULL)
    )
);

CREATE TABLE Address (
    address_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  BIGINT NOT NULL REFERENCES Customer(customer_id),
    recipient    VARCHAR(150) NOT NULL,
    address_type VARCHAR(10) NOT NULL DEFAULT 'HOME' CHECK (address_type IN ('HOME','OFFICE','HOTEL')),
    street       VARCHAR(255) NOT NULL,
    city         VARCHAR(100) NOT NULL DEFAULT 'Ho Chi Minh City',
    latitude     NUMERIC(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude    NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    status       VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED')),
    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Brand (
    brand_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_name VARCHAR(120) NOT NULL UNIQUE,
    status     VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED'))
);

CREATE TABLE MenuItem (
    item_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_id     BIGINT NOT NULL REFERENCES Brand(brand_id),
    item_name    VARCHAR(150) NOT NULL,
    price        NUMERIC(12,2) NOT NULL CHECK (price > 0),
    is_available BOOLEAN NOT NULL DEFAULT TRUE,
    status       VARCHAR(12) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','ARCHIVED')),
    UNIQUE (brand_id, item_name)
);

CREATE TABLE Voucher (
    voucher_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             VARCHAR(40) NOT NULL UNIQUE,
    discount_type    VARCHAR(8)  NOT NULL CHECK (discount_type IN ('PERCENT','FIXED')),
    discount_value   NUMERIC(12,2) NOT NULL CHECK (discount_value > 0),
    max_discount     NUMERIC(12,2) CHECK (max_discount > 0),
    min_order_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (min_order_amount >= 0),
    valid_from       TIMESTAMP NOT NULL,
    valid_to         TIMESTAMP NOT NULL,
    status           VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
    CHECK (valid_to > valid_from),
    CHECK (discount_type <> 'PERCENT' OR discount_value <= 100)
);

CREATE TABLE CustomerOrder (            -- "Order" is a reserved word, so the table is CustomerOrder
    order_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   BIGINT NOT NULL REFERENCES Customer(customer_id),
    hub_id        BIGINT NOT NULL REFERENCES Hub(hub_id),
    address_id    BIGINT NOT NULL REFERENCES Address(address_id),
    voucher_id    BIGINT REFERENCES Voucher(voucher_id),      -- NULL or exactly one voucher
    status        VARCHAR(16) NOT NULL DEFAULT 'PENDING_REVIEW'
                  CHECK (status IN ('PENDING_PAYMENT','PAYMENT_FAILED','PENDING_REVIEW','OVERDUE',
                                    'ACCEPTED','REJECTED','CANCELLED',
                                    'PREPARING','READY','PICKED_UP','DELIVERED','DELIVERY_FAILED')),
    distance_km   NUMERIC(5,2)  NOT NULL CHECK (distance_km >= 0),
    subtotal      NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
    delivery_fee  NUMERIC(12,2) NOT NULL CHECK (delivery_fee >= 0),
    surcharge     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (surcharge >= 0),
    discount      NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
    total         NUMERIC(12,2) NOT NULL CHECK (total >= 0),
    load_units    INTEGER NOT NULL DEFAULT 1 CHECK (load_units > 0),   -- kitchen capacity held
    reject_reason VARCHAR(255),
    cancel_reason VARCHAR(255),
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (discount <= subtotal),
    CHECK (total = subtotal + delivery_fee + surcharge - discount),
    CHECK (status <> 'REJECTED'  OR reject_reason IS NOT NULL),
    CHECK (voucher_id IS NOT NULL OR discount = 0)
);

CREATE TABLE OrderLine (
    order_line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      BIGINT NOT NULL REFERENCES CustomerOrder(order_id),
    item_id       BIGINT NOT NULL REFERENCES MenuItem(item_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(12,2) NOT NULL CHECK (unit_price > 0),   -- price snapshot at order time
    line_total    NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    UNIQUE (order_id, item_id)
);

CREATE TABLE Payment (
    payment_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      BIGINT NOT NULL UNIQUE REFERENCES CustomerOrder(order_id),   -- 1 : 0..1
    method        VARCHAR(14) NOT NULL CHECK (method IN ('CASH','ONLINE_LOCAL','ONLINE_TOURIST')),
    amount        NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    status        VARCHAR(14) NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','AUTHORIZED','DECLINED','TIMEOUT','CASH_DUE','COLLECTED',
                                    'VOIDED','REFUND_PENDING','REFUNDED','REFUND_FAILED')),
    gateway_ref   VARCHAR(80),
    refund_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (refund_amount >= 0),
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (refund_amount <= amount),
    CHECK (method <> 'CASH' OR status IN ('CASH_DUE','COLLECTED','VOIDED'))
);

CREATE TABLE Delivery (
    delivery_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id       BIGINT NOT NULL UNIQUE REFERENCES CustomerOrder(order_id),  -- 1 : 0..1
    shipper_id     BIGINT REFERENCES StaffAccount(staff_id),
    status         VARCHAR(10) NOT NULL DEFAULT 'ASSIGNED'
                   CHECK (status IN ('ASSIGNED','PICKED_UP','DELIVERED','FAILED')),
    picked_up_at   TIMESTAMP,
    delivered_at   TIMESTAMP,
    failure_reason VARCHAR(255),
    CHECK (delivered_at IS NULL OR picked_up_at IS NOT NULL),
    CHECK (delivered_at IS NULL OR delivered_at >= picked_up_at)
);

CREATE TABLE AuditLog (                 -- actor + timestamp for each audited change (test T-28)
    audit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_type  VARCHAR(10) NOT NULL CHECK (actor_type IN ('CUSTOMER','STAFF','SYSTEM')),
    actor_id    BIGINT,
    entity_name VARCHAR(30) NOT NULL,
    entity_id   BIGINT NOT NULL,
    action      VARCHAR(30) NOT NULL,
    details     VARCHAR(255),           -- never store passport, phone or address data here (NFR4)
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

--Indexes for the frequent look-ups of UC1-UC6
CREATE INDEX idx_address_customer   ON Address(customer_id);
CREATE INDEX idx_menuitem_brand     ON MenuItem(brand_id);
CREATE INDEX idx_order_customer     ON CustomerOrder(customer_id);
CREATE INDEX idx_order_hub_status   ON CustomerOrder(hub_id, status);
CREATE INDEX idx_order_created      ON CustomerOrder(created_at);
CREATE INDEX idx_orderline_order    ON OrderLine(order_id);
CREATE INDEX idx_delivery_shipper   ON Delivery(shipper_id);
CREATE INDEX idx_audit_entity       ON AuditLog(entity_name, entity_id);

--Hub load rule (events S1 and S2): BUSY at the busy threshold, OPEN again at the reopening level.
--Between the 2 levels the previous status is kept (hysteresis). CLOSED is set manually.
CREATE FUNCTION fn_hub_load_status() RETURNS trigger AS $$
BEGIN
    IF NEW.load_status <> 'CLOSED' THEN
        IF NEW.current_load >= NEW.busy_threshold THEN
            NEW.load_status := 'BUSY';
        ELSIF NEW.current_load <= NEW.reopening_threshold THEN
            NEW.load_status := 'OPEN';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_hub_load_status
    BEFORE INSERT OR UPDATE OF current_load ON Hub
    FOR EACH ROW EXECUTE FUNCTION fn_hub_load_status();

--Sample data ---------------------------------------------------
--(password_hash values are fake placeholders, not real hashes)

INSERT INTO Hub (hub_name, location, latitude, longitude, capacity_limit,
                 busy_threshold, reopening_threshold, max_delivery_km) VALUES
 ('Hub District 1', '25 Le Thanh Ton, District 1',       10.779000, 106.703000, 30, 24, 15, 5.00),
 ('Hub Binh Thanh', '120 Dien Bien Phu, Binh Thanh',     10.797000, 106.707000, 25, 20, 12, 5.00),
 ('Hub Thu Duc',    '8 Vo Van Ngan, Thu Duc City',       10.850000, 106.758000, 20, 16, 10, 5.00);

INSERT INTO StaffAccount (full_name, email, password_hash, role, hub_id)
SELECT v.name, v.email, v.pw, v.role, h.hub_id
FROM (VALUES
 ('Le Minh Khoa',  'khoa@saigonbite.example',    '$2b$12$sample01', 'KITCHEN_STAFF', 'Hub District 1'),
 ('Pham Thu Ha',   'ha@saigonbite.example',      '$2b$12$sample02', 'KITCHEN_STAFF', 'Hub Binh Thanh'),
 ('Vo Quoc Dat',   'dat@saigonbite.example',     '$2b$12$sample03', 'SHIPPER',       'Hub Binh Thanh'),
 ('Do Thanh Mai',  'mai@saigonbite.example',     '$2b$12$sample04', 'ADMIN',         NULL),
 ('Hoang Gia Bao', 'bao@saigonbite.example',     '$2b$12$sample05', 'MANAGER',       NULL)
) AS v(name, email, pw, role, hub)
LEFT JOIN Hub h ON h.hub_name = v.hub;

INSERT INTO Customer (customer_type, full_name, phone, email, passport_ref, password_hash) VALUES
 ('LOCAL',   'Nguyen Van An', '0901234567', 'an@example.com',   NULL,          '$2b$12$sample11'),
 ('LOCAL',   'Tran Thi Binh', '0912345678', NULL,               NULL,          '$2b$12$sample12'),
 ('TOURIST', 'John Miller',   NULL,         'john@example.com', 'PASSREF-0001', '$2b$12$sample13');

INSERT INTO Address (customer_id, recipient, address_type, street, latitude, longitude)
SELECT c.customer_id, v.recipient, v.atype, v.street, v.lat, v.lng
FROM (VALUES
 ('0901234567',     'Nguyen Van An', 'HOME',   '45 Nguyen Hue, District 1',        10.774000, 106.704000),
 ('0901234567',     'Nguyen Van An', 'OFFICE', '72 Le Lai, District 1',            10.771000, 106.692000),
 ('0912345678',     'Tran Thi Binh', 'HOME',   '15 Xo Viet Nghe Tinh, Binh Thanh', 10.801000, 106.711000),
 ('john@example.com','John Miller',  'HOTEL',  'Hotel Majestic, 1 Dong Khoi, D1',  10.773000, 106.706000)
) AS v(who, recipient, atype, street, lat, lng)
JOIN Customer c ON v.who IN (c.phone, c.email);

INSERT INTO Brand (brand_name) VALUES ('Pho Saigon'), ('Banh Mi Express'), ('Green Bowl Salad');

INSERT INTO MenuItem (brand_id, item_name, price, is_available, status)
SELECT b.brand_id, v.item, v.price, v.avail, v.status
FROM (VALUES
 ('Pho Saigon',       'Pho Bo Tai (rare beef)',  65000, TRUE,  'ACTIVE'),
 ('Pho Saigon',       'Pho Ga (chicken)',        60000, TRUE,  'ACTIVE'),
 ('Pho Saigon',       'Quay (fried dough)',      10000, TRUE,  'ACTIVE'),
 ('Banh Mi Express',  'Banh Mi Thit Nuong',      35000, TRUE,  'ACTIVE'),
 ('Banh Mi Express',  'Banh Mi Op La',           30000, TRUE,  'ACTIVE'),
 ('Banh Mi Express',  'Banh Mi Cha Lua',         28000, TRUE,  'ACTIVE'),
 ('Banh Mi Express',  'Banh Mi Pate (retired)',  25000, FALSE, 'ARCHIVED'),
 ('Green Bowl Salad', 'Chicken Caesar Salad',    55000, TRUE,  'ACTIVE'),
 ('Green Bowl Salad', 'Papaya Salad',            45000, TRUE,  'ACTIVE'),
 ('Green Bowl Salad', 'Quinoa Veggie Bowl',      60000, FALSE, 'ACTIVE')   -- sold out today
) AS v(brand, item, price, avail, status)
JOIN Brand b ON b.brand_name = v.brand;

INSERT INTO Voucher (code, discount_type, discount_value, max_discount, min_order_amount,
                     valid_from, valid_to) VALUES
 ('WELCOME10',   'PERCENT', 10,    30000, 100000, '2026-01-01 00:00', '2026-12-31 23:59'),
 ('FREESHIP15K', 'FIXED',   15000, NULL,   80000, '2026-01-01 00:00', '2026-12-31 23:59'),
 ('SUMMER5',     'PERCENT', 5,     20000,  50000, '2026-06-01 00:00', '2026-06-30 23:59'); -- expired

-- Eight orders, one for each interesting state of the UC2, UC3 and UC4 state machines
INSERT INTO CustomerOrder (customer_id, hub_id, address_id, voucher_id, status, distance_km,
                           subtotal, delivery_fee, discount, total, load_units,
                           reject_reason, cancel_reason, created_at, updated_at)
SELECT c.customer_id, h.hub_id, a.address_id, v.voucher_id, x.status, x.dist,
       x.sub, x.fee, x.disc, x.total, x.units, x.rej, x.canc,
       x.created::timestamp, x.updated::timestamp
FROM (VALUES
 (1, '0901234567', 'Hub District 1', '45 Nguyen Hue%', 'WELCOME10',   -- UC2/UC4: pending, % voucher
     'PENDING_REVIEW', 2.40, 150000, 15000, 15000, 150000, 4, NULL, NULL,
     '2026-11-17 11:45', '2026-11-17 11:45'),
 (2, '0912345678', 'Hub Binh Thanh', '15 Xo Viet%', 'FREESHIP15K',    -- UC4: accepted, fixed voucher
     'ACCEPTED', 1.20, 105000, 15000, 15000, 105000, 3, NULL, NULL,
     '2026-11-17 11:30', '2026-11-17 11:36'),
 (3, 'john@example.com', 'Hub District 1', 'Hotel Majestic%', NULL,   -- UC3: cancelled after online payment
     'CANCELLED', 1.10, 100000, 15000, 0, 115000, 2, NULL, 'Customer changed plans',
     '2026-11-17 10:20', '2026-11-17 10:24'),
 (4, '0901234567', 'Hub District 1', '72 Le Lai%', NULL,              -- UC4: rejected by the kitchen
     'REJECTED', 3.10, 60000, 15000, 0, 75000, 1, 'Ingredient sold out', NULL,
     '2026-11-16 18:05', '2026-11-16 18:09'),
 (5, '0912345678', 'Hub Binh Thanh', '15 Xo Viet%', NULL,             -- delivered, has an archived item (A-05)
     'DELIVERED', 3.80, 81000, 20000, 0, 101000, 3, NULL, NULL,
     '2026-11-16 12:00', '2026-11-16 12:55'),
 (6, 'john@example.com', 'Hub District 1', 'Hotel Majestic%', NULL,   -- UC2: tourist, online payment pending
     'PENDING_PAYMENT', 1.10, 120000, 15000, 0, 135000, 2, NULL, NULL,
     '2026-11-17 11:50', '2026-11-17 11:50'),
 (7, '0912345678', 'Hub Binh Thanh', '15 Xo Viet%', NULL,             -- T1: kitchen did not answer in time
     'OVERDUE', 1.20, 60000, 15000, 0, 75000, 1, NULL, NULL,
     '2026-11-17 10:00', '2026-11-17 10:20'),
 (8, '0901234567', 'Hub District 1', '45 Nguyen Hue%', NULL,          -- UC2: card declined, customer may retry
     'PAYMENT_FAILED', 2.40, 120000, 15000, 0, 135000, 2, NULL, NULL,
     '2026-11-17 11:55', '2026-11-17 11:56')
) AS x(seq, who, hub, street, vcode, status, dist, sub, fee, disc, total, units, rej, canc, created, updated)
JOIN Customer c ON x.who IN (c.phone, c.email)
JOIN Hub h      ON h.hub_name = x.hub
JOIN Address a  ON a.customer_id = c.customer_id AND a.street LIKE x.street
LEFT JOIN Voucher v ON v.code = x.vcode
ORDER BY x.seq;

--Order lines (an order is identified by its customer and creation time)
INSERT INTO OrderLine (order_id, item_id, quantity, unit_price)
SELECT o.order_id, i.item_id, x.qty, i.price
FROM (VALUES
 ('0901234567', '2026-11-17 11:45', 'Pho Bo Tai (rare beef)', 2),
 ('0901234567', '2026-11-17 11:45', 'Quay (fried dough)',     2),
 ('0912345678', '2026-11-17 11:30', 'Banh Mi Thit Nuong',     3),
 ('john@example.com', '2026-11-17 10:20', 'Papaya Salad',          1),
 ('john@example.com', '2026-11-17 10:20', 'Chicken Caesar Salad',  1),
 ('0901234567', '2026-11-16 18:05', 'Pho Ga (chicken)',       1),
 ('0912345678', '2026-11-16 12:00', 'Banh Mi Cha Lua',        2),
 ('0912345678', '2026-11-16 12:00', 'Banh Mi Pate (retired)', 1),
 ('john@example.com', '2026-11-17 11:50', 'Pho Bo Tai (rare beef)', 1),
 ('john@example.com', '2026-11-17 11:50', 'Chicken Caesar Salad',   1),
 ('0912345678', '2026-11-17 10:00', 'Quinoa Veggie Bowl',     1),
 ('0901234567', '2026-11-17 11:55', 'Pho Ga (chicken)',       2)
) AS x(who, created, item, qty)
JOIN Customer c ON x.who IN (c.phone, c.email)
JOIN CustomerOrder o ON o.customer_id = c.customer_id AND o.created_at = x.created::timestamp
JOIN MenuItem i ON i.item_name = x.item;

INSERT INTO Payment (order_id, method, amount, status, gateway_ref, refund_amount)
SELECT o.order_id, x.method, o.total, x.status, x.gw, x.refund
FROM (VALUES
 ('0901234567', '2026-11-17 11:45', 'ONLINE_LOCAL',   'AUTHORIZED',     'GW-0001', 0),
 ('0912345678', '2026-11-17 11:30', 'CASH',           'CASH_DUE',       NULL,      0),
 ('john@example.com', '2026-11-17 10:20', 'ONLINE_TOURIST', 'REFUND_PENDING', 'GW-0002', 115000),
 ('0901234567', '2026-11-16 18:05', 'CASH',           'VOIDED',         NULL,      0),
 ('0912345678', '2026-11-16 12:00', 'CASH',           'COLLECTED',      NULL,      0),
 ('john@example.com', '2026-11-17 11:50', 'ONLINE_TOURIST', 'PENDING',  NULL,      0),
 ('0912345678', '2026-11-17 10:00', 'CASH',           'CASH_DUE',       NULL,      0),
 ('0901234567', '2026-11-17 11:55', 'ONLINE_LOCAL',   'DECLINED',       'GW-0003', 0)
) AS x(who, created, method, status, gw, refund)
JOIN Customer c ON x.who IN (c.phone, c.email)
JOIN CustomerOrder o ON o.customer_id = c.customer_id AND o.created_at = x.created::timestamp;

--Delivery of the delivered order (picked up 12:25, delivered 12:55)
INSERT INTO Delivery (order_id, shipper_id, status, picked_up_at, delivered_at)
SELECT o.order_id, s.staff_id, 'DELIVERED', '2026-11-16 12:25', '2026-11-16 12:55'
FROM CustomerOrder o, StaffAccount s
WHERE o.status = 'DELIVERED' AND s.role = 'SHIPPER';

--Hub load = capacity held by orders that have not yet left the kitchen
UPDATE Hub h SET current_load = COALESCE((
    SELECT SUM(o.load_units) FROM CustomerOrder o
    WHERE o.hub_id = h.hub_id
      AND o.status IN ('PENDING_PAYMENT','PAYMENT_FAILED','PENDING_REVIEW','OVERDUE',
                       'ACCEPTED','PREPARING','READY')), 0);

INSERT INTO AuditLog (actor_type, actor_id, entity_name, entity_id, action, details)
SELECT 'STAFF', s.staff_id, 'CustomerOrder', o.order_id, 'REJECT', 'Ingredient sold out'
FROM CustomerOrder o, StaffAccount s
WHERE o.status = 'REJECTED' AND s.role = 'KITCHEN_STAFF' AND s.hub_id = o.hub_id;
