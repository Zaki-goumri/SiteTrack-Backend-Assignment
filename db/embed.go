package sqlfiles

import "embed"

//go:embed migrations/*.sql views/*.sql functions/*.sql seed/*.sql
var FS embed.FS
