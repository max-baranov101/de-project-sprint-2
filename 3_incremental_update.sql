-- удаление предыдущей таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

-- создание DDL таблицы инкрементальных загрузок
CREATE TABLE
    IF NOT EXISTS dwh.load_dates_customer_report_datamart (
        id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
        load_dttm DATE NOT NULL,
        CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
    );

-- инкрементальная загрузка
WITH
    dwh_delta AS (
        SELECT
            dcs.customer_id AS customer_id,
            dcs.customer_name AS customer_name,
            dcs.customer_address AS customer_address,
            dcs.customer_birthday AS customer_birthday,
            dcs.customer_email AS customer_email,
            dc.craftsman_id as craftsman_id,
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            fo.order_completion_date - fo.order_created_date AS diff_order_date,
            fo.order_status AS order_status,
            TO_CHAR (fo.order_created_date, 'yyyy-mm') AS report_period,
            crd.customer_id AS exist_customer_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm
        FROM
            dwh.f_order fo
            INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
            INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
            INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
            LEFT JOIN dwh.customer_report_datamart crd ON dcs.customer_id = crd.customer_id
            -- определение данных, которые были изменены в витрине или добавлены в DWH
        WHERE
            (
                fo.load_dttm > (
                    SELECT
                        COALESCE(MAX(load_dttm), '1900-01-01')
                    FROM
                        dwh.load_dates_customer_report_datamart
                )
            )
            OR (
                dc.load_dttm > (
                    SELECT
                        COALESCE(MAX(load_dttm), '1900-01-01')
                    FROM
                        dwh.load_dates_customer_report_datamart
                )
            )
            OR (
                dcs.load_dttm > (
                    SELECT
                        COALESCE(MAX(load_dttm), '1900-01-01')
                    FROM
                        dwh.load_dates_customer_report_datamart
                )
            )
            OR (
                dp.load_dttm > (
                    SELECT
                        COALESCE(MAX(load_dttm), '1900-01-01')
                    FROM
                        dwh.load_dates_customer_report_datamart
                )
            )
    ),
    -- выборка заказчиков, по которым были изменения в DWH.
    dwh_update_delta AS (
        SELECT
            dd.exist_customer_id AS customer_id
        FROM
            dwh_delta dd
        WHERE
            dd.exist_customer_id IS NOT NULL
    ),
    --  расчёт витрины по новым данным мастеров в рамках расчётного периода
    dwh_delta_insert_result AS (
        SELECT
            T4.customer_id AS customer_id,
            T4.customer_name AS customer_name,
            T4.customer_address AS customer_address,
            T4.customer_birthday AS customer_birthday,
            T4.customer_email AS customer_email,
            T4.customer_money AS customer_money_pay,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.top_craftsman_id_for_customer AS top_craftsman_id_customer,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period
        FROM
            (
                -- объединение двух внутренних выборок по расчёту столбцов витрины
                SELECT 
                
                    *,
                    -- оконная функция определения самой популярной категории товаров
                    RANK() OVER (
                        PARTITION BY
                            T2.customer_id,
                            T2.report_period
                        ORDER BY
                            count_product DESC
                    ) AS rank_count_product
                FROM
                    (
                        -- расчёт по большинству столбцов
                        SELECT
                            T1.customer_id AS customer_id,
                            T1.customer_name AS customer_name,
                            T1.customer_address AS customer_address,
                            T1.customer_birthday AS customer_birthday,
                            T1.customer_email AS customer_email,
                            SUM(T1.product_price) AS customer_money,
                            SUM(T1.product_price) * 0.1 AS platform_money,
                            COUNT(order_id) AS count_order,
                            AVG(T1.product_price) AS avg_price_order,
                            PERCENTILE_CONT(0.5) WITHIN GROUP (
                                ORDER BY
                                    diff_order_date
                            ) AS median_time_order_completed,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'created' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_created,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'in progress' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_in_progress,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'delivery' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_delivery,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'done' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_done,
                            SUM(
                                CASE
                                    WHEN T1.order_status != 'done' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_not_done,
                            T1.report_period AS report_period
                        FROM
                            dwh_delta AS T1
                        WHERE
                            T1.exist_customer_id IS NULL
                        GROUP BY
                            T1.customer_id,
                            T1.customer_name,
                            T1.customer_address,
                            T1.customer_birthday,
                            T1.customer_email,
                            T1.report_period
                    ) AS T2
                    INNER JOIN (
                        -- самый популярный товар у заказчика
                        SELECT
                            dd.customer_id AS customer_id_for_product_type,
                            dd.product_type,
                            COUNT(dd.product_id) AS count_product
                        FROM
                            dwh_delta AS dd
                        GROUP BY
                            dd.customer_id,
                            dd.product_type
                        ORDER BY
                            count_product DESC
                    ) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
                    LEFT JOIN (
                        SELECT
                            customer_id_for_craftsman,
                            top_craftsman_id_for_customer
                        FROM
                            (
                                SELECT
                                    *,
                                    MAX(T6.count_order_craftsman) OVER (
                                        PARTITION BY
                                            customer_id_for_craftsman,
                                            top_craftsman_id_for_customer
                                    ) AS max_count_craftsman_for_customer
                                FROM
                                    (
                                        -- определение самого популярного мастер у заказчика
                                        SELECT
                                            dd.customer_id AS customer_id_for_craftsman,
                                            dd.craftsman_id AS top_craftsman_id_for_customer,
                                            COUNT(dd.order_id) AS count_order_craftsman
                                        FROM
                                            dwh_delta AS dd
                                        GROUP BY
                                            dd.customer_id,
                                            dd.craftsman_id
                                        ORDER BY
                                            count_order_craftsman desc
                                    ) AS T6
                            ) AS T7
                        WHERE
                            max_count_craftsman_for_customer = count_order_craftsman
                    ) AS T5 ON T2.customer_id = T5.customer_id_for_craftsman
            ) AS T4
        WHERE
            T4.rank_count_product = 1
            -- выбор первого по популярности категории товаров
        ORDER BY
            report_period
    ),
    dwh_delta_update_result AS (
        -- перерасчёт для существующих записей витринs, так как данные обновились за отчётные периоды.
        SELECT
            T4.customer_id AS customer_id,
            T4.customer_name AS customer_name,
            T4.customer_address AS customer_address,
            T4.customer_birthday AS customer_birthday,
            T4.customer_email AS customer_email,
            T4.customer_money AS customer_money_pay,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.top_craftsman_id_for_customer AS top_craftsman_id_customer,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period
        FROM
            (
                -- объединение двух внутренних выборки по расчёту столбцов витрины
                SELECT
                    *,
                    -- оконная функция для определения самой популярной категории товаров
                    RANK() OVER (
                        PARTITION BY
                            T2.customer_id,
                            T2.report_period
                        ORDER BY
                            count_product DESC
                    ) AS rank_count_product
                FROM
                    (
                        -- расчёты по большинству столбцов
                        SELECT
                            T1.customer_id AS customer_id,
                            T1.customer_name AS customer_name,
                            T1.customer_address AS customer_address,
                            T1.customer_birthday AS customer_birthday,
                            T1.customer_email AS customer_email,
                            SUM(T1.product_price) AS customer_money,
                            SUM(T1.product_price) * 0.1 AS platform_money,
                            COUNT(order_id) AS count_order,
                            AVG(T1.product_price) AS avg_price_order,
                            PERCENTILE_CONT(0.5) WITHIN GROUP (
                                ORDER BY
                                    diff_order_date
                            ) AS median_time_order_completed,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'created' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_created,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'in progress' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_in_progress,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'delivery' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_delivery,
                            SUM(
                                CASE
                                    WHEN T1.order_status = 'done' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_done,
                            SUM(
                                CASE
                                    WHEN T1.order_status != 'done' THEN 1
                                    ELSE 0
                                END
                            ) AS count_order_not_done,
                            T1.report_period AS report_period
                        FROM
                            (
                                -- выборка обновлённых или новых данные по заказчикам, которые уже есть в витрине
                                SELECT
                                    dcs.customer_id AS customer_id,
                                    dcs.customer_name AS customer_name,
                                    dcs.customer_address AS customer_address,
                                    dcs.customer_birthday AS customer_birthday,
                                    dcs.customer_email AS customer_email,
                                    fo.order_id AS order_id,
                                    dp.product_id AS product_id,
                                    dp.product_price AS product_price,
                                    dp.product_type AS product_type,
                                    fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                    fo.order_status AS order_status,
                                    TO_CHAR (fo.order_created_date, 'yyyy-mm') AS report_period
                                FROM
                                    dwh.f_order fo
                                    INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
                                    INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
                                    INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                    INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
                            ) AS T1
                        GROUP BY
                            T1.customer_id,
                            T1.customer_name,
                            T1.customer_address,
                            T1.customer_birthday,
                            T1.customer_email,
                            T1.report_period
                    ) AS T2
                    -- определение самого популярного товара у заказчика
                    INNER JOIN (
                        SELECT
                            dd.customer_id AS customer_id_for_product_type,
                            dd.product_type,
                            COUNT(dd.product_id) AS count_product
                        FROM
                            dwh_delta AS dd
                        GROUP BY
                            dd.customer_id,
                            dd.product_type
                        ORDER BY
                            count_product DESC
                    ) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
                    LEFT JOIN (
                        SELECT
                            customer_id_for_craftsman,
                            top_craftsman_id_for_customer
                        FROM
                            (
                                SELECT
                                    *,
                                    MAX(T6.count_order_craftsman) OVER (
                                        PARTITION BY
                                            customer_id_for_craftsman,
                                            top_craftsman_id_for_customer
                                    ) AS max_count_craftsman_for_customer
                                FROM
                                    (
                                        -- определение самого популярного мастер у заказчика
                                        SELECT
                                            dd.customer_id AS customer_id_for_craftsman,
                                            dd.craftsman_id AS top_craftsman_id_for_customer,
                                            COUNT(dd.order_id) AS count_order_craftsman
                                        FROM
                                            dwh_delta AS dd
                                        GROUP BY
                                            dd.customer_id,
                                            dd.craftsman_id
                                        ORDER BY
                                            count_order_craftsman desc
                                    ) AS T6
                            ) AS T7
                        WHERE
                            max_count_craftsman_for_customer = count_order_craftsman
                    ) AS T5 ON T2.customer_id = T5.customer_id_for_craftsman
            ) AS T4
        WHERE
            T4.rank_count_product = 1
        ORDER BY
            report_period
    ),
    -- insert новых расчитанных данных для витрины 
    insert_delta AS (
        INSERT INTO
            dwh.customer_report_datamart (
                customer_id,
                customer_name,
                customer_address,
                customer_birthday,
                customer_email,
                customer_money_pay,
                platform_money,
                count_order,
                avg_price_order,
                median_time_order_completed,
                top_product_category,
                top_craftsman_id_customer,
                count_order_created,
                count_order_in_progress,
                count_order_delivery,
                count_order_done,
                count_order_not_done,
                report_period
            )
        SELECT
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money_pay,
            platform_money,
            count_order,
            avg_price_order,
            median_time_order_completed,
            top_product_category,
            top_craftsman_id_customer,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period
        FROM
            dwh_delta_insert_result
    ),
    -- обновление показателей в отчёте по уже существующим заказчикам
    update_delta AS (
        UPDATE dwh.customer_report_datamart
        SET
            customer_name = updates.customer_name,
            customer_address = updates.customer_address,
            customer_birthday = updates.customer_birthday,
            customer_email = updates.customer_email,
            customer_money_pay = updates.customer_money_pay,
            platform_money = updates.platform_money,
            count_order = updates.count_order,
            avg_price_order = updates.avg_price_order,
            median_time_order_completed = updates.median_time_order_completed,
            top_product_category = updates.top_product_category,
            top_craftsman_id_customer = updates.top_craftsman_id_customer,
            count_order_created = updates.count_order_created,
            count_order_in_progress = updates.count_order_in_progress,
            count_order_delivery = updates.count_order_delivery,
            count_order_done = updates.count_order_done,
            count_order_not_done = updates.count_order_not_done,
            report_period = updates.report_period
        FROM
            (
                SELECT
                    customer_id,
                    customer_name,
                    customer_address,
                    customer_birthday,
                    customer_email,
                    customer_money_pay,
                    platform_money,
                    count_order,
                    avg_price_order,
                    median_time_order_completed,
                    top_product_category,
                    top_craftsman_id_customer,
                    count_order_created,
                    count_order_in_progress,
                    count_order_delivery,
                    count_order_done,
                    count_order_not_done,
                    report_period
                FROM
                    dwh_delta_update_result
            ) AS updates
        WHERE
            dwh.customer_report_datamart.customer_id = updates.customer_id
    ),
    -- добавление в таблицу загрузок новой записи о времени загрузки
    insert_load_date AS (
        INSERT INTO
            dwh.load_dates_customer_report_datamart (load_dttm)
        SELECT
            GREATEST (
                COALESCE(MAX(craftsman_load_dttm), NOW ()),
                COALESCE(MAX(customers_load_dttm), NOW ()),
                COALESCE(MAX(products_load_dttm), NOW ())
            )
        FROM
            dwh_delta
    )
    -- инициализируем запрос CTE
SELECT
    'increment datamart';