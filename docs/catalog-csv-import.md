# Catalog CSV import

Catalog import accepts a user-selected UTF-8 CSV file. Import is optional and does not connect to a retailer, receipt provider, or other account.

The first row must contain these required columns:

- `source_id`: a stable name for the system or file family that produced the row.
- `item_id`: the stable item identifier within that source.
- `name`: the catalog item name.

These columns are optional:

- `notes`: saved catalog notes.
- `category`: the exact name of an existing household category.
- `stores`: exact names of existing active household stores, separated with semicolons. Blank means Any store.

Example:

```csv
source_id,item_id,name,notes,category,stores
family-export,001,Whole milk,2%,Dairy,Publix;Costco
family-export,002,Apples,Honeycrisp,Produce,
```

Fields containing commas, quotes, or line breaks follow standard CSV quoting rules. For example, write `"Bread, sliced"` and escape an embedded quote as `""`.

## Review and repeat imports

The app shows every row before writing anything. New rows default to **Import new item**. A row whose `source_id` and `item_id` were imported before defaults to **Skip** and can be changed to **Update linked item**. A name matching a different catalog item also defaults to **Skip** and can be changed to **Import separately**. The importer never silently merges distinct items.

Within a household, the pair `source_id` and `item_id` is the stable import identity. Reusing that pair on later imports targets the same catalog item, so a repeated import cannot create another copy unless the source changes its identity. The same source identity can be imported independently into another household.

Rows with missing required values, duplicate source identities, or extra columns remain visible in the preview and are skipped. Unknown or ambiguous category and store names are handled the same way. Correct the CSV or the household catalog data, then import again. Archived stores must be restored before they can be assigned.

The final confirmation applies only the rows and actions in that preview. If an affected item or name collision changes after preview, that row is reported as changed and is not overwritten.
