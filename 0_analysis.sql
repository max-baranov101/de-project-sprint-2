--  Запрос получения колонок таблицы dwh.d_craftsman
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dwh'
AND table_name = 'd_craftsman';

-- Запрос получения колонок таблицы dwh.d_product
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dwh'
AND table_name = 'd_product';

-- Запрос получения колонок таблицы dwh.d_customer
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dwh'
AND table_name = 'd_customer';

-- Запрос получения колонок таблицы dwh.f_order
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dwh'
AND table_name = 'f_order';

-- Запрос получения колонок таблицы craft_products_orders
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'external_source'
AND table_name = 'craft_products_orders';


-- Запрос получения колонок таблицы customers
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'external_source'
AND table_name = 'customers';