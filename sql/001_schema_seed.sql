CREATE TABLE funds (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    vintage_year integer NOT NULL,
    target_size_usd numeric(14, 2) NOT NULL,
    status text NOT NULL CHECK (status IN ('raising', 'active', 'closed'))
);

CREATE TABLE investors (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    investor_type text NOT NULL,
    committed_capital_usd numeric(14, 2) NOT NULL,
    joined_at date NOT NULL
);

CREATE TABLE capital_calls (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fund_id integer NOT NULL REFERENCES funds(id),
    investor_id integer NOT NULL REFERENCES investors(id),
    call_date date NOT NULL,
    amount_usd numeric(14, 2) NOT NULL,
    status text NOT NULL CHECK (status IN ('scheduled', 'paid', 'late'))
);

INSERT INTO funds (name, vintage_year, target_size_usd, status)
SELECT
    'Fundwave Growth Fund ' || series,
    2018 + (series % 7),
    (50000000 + (series * 1250000))::numeric,
    CASE series % 3 WHEN 0 THEN 'raising' WHEN 1 THEN 'active' ELSE 'closed' END
FROM generate_series(1, 12) AS series;

INSERT INTO investors (name, investor_type, committed_capital_usd, joined_at)
SELECT
    'Investor ' || lpad(series::text, 4, '0'),
    CASE series % 4 WHEN 0 THEN 'family_office' WHEN 1 THEN 'pension' WHEN 2 THEN 'endowment' ELSE 'fund_of_funds' END,
    (250000 + (series * 7500))::numeric,
    DATE '2021-01-01' + ((series % 900) * INTERVAL '1 day')
FROM generate_series(1, 1500) AS series;

INSERT INTO capital_calls (fund_id, investor_id, call_date, amount_usd, status)
SELECT
    ((series - 1) % 12) + 1,
    ((series - 1) % 1500) + 1,
    DATE '2023-01-01' + ((series % 950) * INTERVAL '1 day'),
    (10000 + (series % 250) * 1250)::numeric,
    CASE series % 5 WHEN 0 THEN 'scheduled' WHEN 1 THEN 'late' ELSE 'paid' END
FROM generate_series(1, 4500) AS series;

