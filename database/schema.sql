CREATE TABLE IF NOT EXISTS `bcc_wagon_hunting_cargo` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `wagon_id` INT UNSIGNED NOT NULL,
    `carcass_key` VARCHAR(64) NOT NULL COMMENT 'Unique load token; network IDs alone are recycled',
    `model_hash` BIGINT NOT NULL,
    `cargo_units` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `quality` TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Native carcass quality: 0=poor, 1=good, 2=perfect',
    `is_skinned` TINYINT(1) NOT NULL DEFAULT 0,
    `outfit_hash` BIGINT NOT NULL DEFAULT 0,
    `meta_tags` LONGTEXT NULL,
    `stored_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_bcc_hunting_carcass` (`wagon_id`, `carcass_key`),
    KEY `idx_bcc_hunting_wagon` (`wagon_id`),
    CONSTRAINT `fk_bcc_hunting_wagon`
        FOREIGN KEY (`wagon_id`) REFERENCES `bcc_player_wagons` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
