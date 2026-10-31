-- The `mysqlmacclient_test` schema the database tests expect. Each test
-- resets the rows it relies on, so only the structure has to be here.
CREATE DATABASE IF NOT EXISTS mysqlmacclient_test;
USE mysqlmacclient_test;

-- Aria, not InnoDB, like XAMPP's default: TableImportViewModelTests relies on
-- `widgets` not supporting ROLLBACK and uses its own InnoDB table for that.
CREATE TABLE widgets (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    quantity INT NULL,
    created_at DATETIME NULL,
    notes TEXT NULL,
    KEY idx_name_quantity (name, quantity)
) ENGINE=Aria;

CREATE TABLE widget_logs_nopk (
    widget_id INT NULL,
    message VARCHAR(255) NULL,
    logged_at DATETIME NULL
) ENGINE=InnoDB;

CREATE TABLE tags (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NULL
) ENGINE=InnoDB;

CREATE TABLE manual_pk_items (
    item_code INT NOT NULL PRIMARY KEY,
    label VARCHAR(100) NULL
) ENGINE=InnoDB;

CREATE VIEW widget_view AS SELECT id, name, quantity FROM widgets;
