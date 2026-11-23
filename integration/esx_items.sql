-- ESX Legacy default inventory item registration.
-- Back up the database first and adapt columns if your ESX fork differs.
INSERT IGNORE INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`) VALUES
    ('rs_thruster_kit', 'RS Thruster Kit', 6000, 0, 1),
    ('rs_thruster_refill', 'Thruster Gas Cartridge', 1800, 0, 1);
