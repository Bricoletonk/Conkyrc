-- Machine principale : disques de données et sauvegarde Timeshift
-- (un disque non monté est simplement ignoré)
return {
    disques = {
        { "/", "M.2" },
        { "/media/bricole/Data Laptop", "DATA" },
        { "/run/timeshift/backup", "BCKP" },
    },
    villes = { "Bruxelles", "Colmar" },
}
