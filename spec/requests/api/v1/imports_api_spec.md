
# API: Full Import Pipeline for TransactionImport

## Problem

The current API only exposes `POST /imports` (create) for `TransactionImport`. It builds the import with column labels, generates rows, and optionally triggers `publish_later` if `params[:publish] == "true"`. But `publish_later` calls `publishable?` which requires:

1. `cleaned?` — all rows must be valid
2. `mappings.all?(&:valid?)` — all mappings must be assigned

Neither happens during `create` because:
- `sync_mappings()` is **never called** — it's only invoked by the web UI's `Import::ConfigurationsController#update`
- Row validation runs during `generate_rows_from_csv`, but without column labels set on the import object, `csv_value()` returns nil for everything, making every row invalid
- The API routes only declare `[ :index, :show, :create ]` — no `update`, `publish`, `clean`, or `configuration` endpoints

This means API consumers can create an import but can never complete it.

## Goal

Add complete import lifecycle to the API:

```
POST   /api/v1/imports              — Create import + upload CSV
PUT    /api/v1/imports/:id          — Update configuration (column mappings)
GET    /api/v1/imports/:id/preflight — Validate CSV structure without committing
POST   /api/v1/imports/:id/clean    — Validate rows, return errors
POST   /api/v1/imports/:id/publish  — Execute the import (create transactions)
GET    /api/v1/imports/:id          — Get status/stats at any stage
DELETE /api/v1/imports/:id          — Cancel/destroy import
```

## Implementation Plan

### 1. Routes

Edit `config/routes.rb` to add `update`, `destroy`, and member routes to the API imports block:

```ruby
resources :imports, only: [ :index, :show, :create, :update, :destroy ] do
  post :preflight, on: :collection
  get :rows, on: :member
  post :clean, on: :member
  post :publish, on: :member
  post :revert, on: :member
  put :apply_template, on: :member
end
```

### 2. Controller: Add update, clean, publish, revert, destroy to `Api::V1::ImportsController`

#### `update` — Set column labels and regenerate mappings

```ruby
def update
  authorize_scope!(:write)

  @import = import_scope.find(params[:id])

  # If column labels are provided, regenerate rows and mappings
  if import_config_params.any?
    @import.update!(import_config_params)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload
  end

  render :show
rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
  render json: { error: "validation_failed", message: e.message }, status: :unprocessable_entity
rescue StandardError => e
  Rails.logger.error "ImportsController#update error: #{e.message}"
  render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
end
```

#### `clean` — Validate rows and return errors

```ruby
def clean
  authorize_scope!(:write)

  @import = import_scope.find(params[:id])

  # Re-validate all rows
  @import.rows.each(&:valid?)
  @import.reload

  invalid_count = @import.rows.count(&:invalid?)
  valid_count = @import.rows.count(&:valid?)

  render json: {
    data: {
      id: @import.id,
      status: @import.status,
      status_detail: {
        uploaded: @import.uploaded?,
        configured: @import.configured?,
        terminal: @import.cleaned?,
        cleaned: @import.cleaned?,
        publishable: @import.publishable?,
        revertable: @import.revertable?
      },
      stats: {
        rows_count: @import.rows_count,
        valid_rows_count: valid_count,
        invalid_rows_count: invalid_count,
        mappings_count: @import.mappings_count,
        unassigned_mappings_count: @import.unassigned_mappings_count
      },
      errors: @import.rows.select(&:invalid?).map do |row|
        {
          row_number: row.row_number,
          errors: row.errors.full_messages
        }
      end
    }
  }
rescue StandardError => e
  Rails.logger.error "ImportsController#clean error: #{e.message}"
  render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
end
```

#### `publish` — Execute the import synchronously

```ruby
def publish
  authorize_scope!(:write)

  @import = import_scope.find(params[:id])

  begin
    @import.publish
    @import.reload

    render json: {
      data: {
        id: @import.id,
        status: @import.status,
        stats: @import.stats,
        status_detail: {
          uploaded: @import.uploaded?,
          configured: @import.configured?,
          terminal: @import.cleaned?,
          cleaned: @import.cleaned?,
          publishable: @import.publishable?,
          revertable: @import.revertable?
        }
      }
    }
  rescue Import::MaxRowCountExceededError
    render json: {
      error: "max_row_count_exceeded",
      message: "Import has too many rows to publish.",
      import_id: @import.id
    }, status: :unprocessable_entity
  rescue Import::MappingError, ActiveRecord::RecordInvalid => e
    render json: {
      error: "publish_failed",
      message: e.message,
      import_id: @import.id
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#publish error: #{e.message}"
    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred."
    }, status: :internal_server_error
  end
end
```

#### `revert` — Roll back an import

```ruby
def revert
  authorize_scope!(:write)

  @import = import_scope.find(params[:id])

  begin
    @import.revert
    @import.reload

    render json: {
      data: {
        id: @import.id,
        status: @import.status
      }
    }
  rescue => e
    render json: {
      error: "revert_failed",
      message: e.message,
      import_id: @import.id
    }, status: :unprocessable_entity
  end
end
```

#### `destroy` — Delete an import

```ruby
def destroy
  authorize_scope!(:write)

  @import = import_scope.find(params[:id])

  # Only allow destroying pending or failed imports
  unless @import.pending? || @import.failed? || @import.revert_failed?
    render json: {
      error: "cannot_destroy",
      message: "Cannot destroy an import that has been published or is in progress."
    }, status: :unprocessable_entity
    return
  end

  @import.destroy

  head :no_content
rescue StandardError => e
  Rails.logger.error "ImportsController#destroy error: #{e.message}"
  render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
end
```

### 3. Schema: Add `external_id` and `source` to import rows

The existing `generate_rows_from_csv` already reads `external_id` and `source` from CSV rows (lines 283-284 of `import.rb`), but the `import_rows` table may not have these columns. The migration from the fork (`20260722000000_add_external_id_and_source_to_import_rows.rb`) adds them. Include it in the PR.

### 4. Preflight endpoint (bonus)

The `preflight` action already exists but may need updating to handle the new column mappings. It validates CSV structure and returns a preview of parsed rows without creating a persistent import record.

### 5. Request/Response Examples

#### Create import

```bash
POST /api/v1/imports
X-Api-Key: <key>
Content-Type: application/json

{
  "type": "TransactionImport",
  "account_id": "00000000-0000-0000-0000-000000000000",
  "raw_file_content": "date,amount,name,currency,...\nYYYY-MM-DD,-100.00,...\n",
  "rows_to_skip": 1
}
```

Response:
```json
{
  "data": {
    "id": "abc123",
    "type": "TransactionImport",
    "status": "pending",
    "stats": {
      "rows_count": 441,
      "valid_rows_count": 0,
      "invalid_rows_count": 0,
      "mappings_count": 0
    },
    "status_detail": {
      "uploaded": true,
      "configured": true,
      "terminal": false,
      "cleaned": false,
      "publishable": false,
      "revertable": false
    }
  }
}
```

#### Update configuration

```bash
PUT /api/v1/imports/abc123
X-Api-Key: <key>
Content-Type: application/json

{
  "date_col_label": "date",
  "amount_col_label": "amount",
  "name_col_label": "name",
  "currency_col_label": "currency",
  "category_col_label": "category",
  "tags_col_label": "tags",
  "notes_col_label": "notes"
}
```

#### Clean (validate rows)

```bash
POST /api/v1/imports/abc123/clean
X-Api-Key: <key>
```

Response:
```json
{
  "data": {
    "id": "abc123",
    "status": "pending",
    "stats": {
      "rows_count": 441,
      "valid_rows_count": 436,
      "invalid_rows_count": 5
    },
    "errors": [
      { "row_number": 12, "errors": ["Date is not a valid date"] },
      { "row_number": 45, "errors": ["Amount is not a valid number"] }
    ]
  }
}
```

#### Publish

```bash
POST /api/v1/imports/abc123/publish
X-Api-Key: <key>
```

Response:
```json
{
  "data": {
    "id": "abc123",
    "status": "complete",
    "stats": {
      "rows_count": 441,
      "valid_rows_count": 436,
      "invalid_rows_count": 5
    },
    "status_detail": {
      "uploaded": true,
      "configured": true,
      "terminal": true,
      "cleaned": true,
      "publishable": true,
      "revertable": true
    }
  }
}
```

#### Publish with auto-dedup

When CSV rows include `external_id` and `source` columns, the `TransactionImport#import!` method uses them for duplicate detection via `Account::ProviderImportAdapter#find_duplicate_transaction`. If a matching transaction already exists (same external_id + source), it updates the existing entry instead of creating a new one.

### 6. Edge Cases

- **Large files (441+ rows)**: The `publish` endpoint runs synchronously. For very large imports (>1000 rows), consider adding `async: true` param to queue via `publish_later` instead. The existing `publish_later` + `ImportJob` pattern already handles this for the web UI.
- **Transaction naming conflicts**: DSB transaction names contain slashes and special chars (e.g., `POS TRANSACTION MERCHANT NAME / - / -`). Ensure CSV quoting is handled correctly by Rails' CSV parser.
- **Currency mapping**: If the CSV `currency` column is blank, the adapter falls back to `account.currency` then `family.currency`.
- **Category/Tag mapping**: If categories or tags in the CSV don't exist, `sync_mappings` creates them as new `Import::CategoryMapping`/`Import::TagMapping` records with `create_when_empty = true`. The actual `Category`/`Tag` records are created during `import!`.
- **Rollback on failure**: If `import!` raises during publishing, the ActiveRecord transaction rolls back all created/updated entries. The import record is set to `status: "failed"` with the error message.

### 7. Testing

Add request specs for the new endpoints:

```ruby
RSpec.describe "Api::V1::Imports", type: :request do
  let(:api_key) { create(:api_key, family: family, scopes: [:write]) }
  let!(:account) { create(:account, family: family, currency: "SRD") }

  describe "POST /api/v1/imports" do
    it "creates import with CSV content" do
      # Test creation, row generation, stats
    end

    it "returns 422 for file too large" do
      # Test 10MB+ limit
    end

    it "returns 403 for unauthorized" do
      # Test missing/invalid API key
    end
  end

  describe "PUT /api/v1/imports/:id" do
    it "sets column labels and syncs mappings" do
      # Create import -> update with column labels -> verify rows valid
    end

    it "regenerates rows on column label change" do
      # Change date_col_label -> rows should be regenerated
    end
  end

  describe "POST /api/v1/imports/:id/clean" do
    it "validates rows and returns errors" do
      # Import with bad dates -> clean -> see errors
    end

    it "marks import as publishable when all rows valid" do
      # All rows valid -> clean -> publishable: true
    end
  end

  describe "POST /api/v1/imports/:id/publish" do
    it "creates transactions from valid rows" do
      # Import 10 rows -> publish -> verify 10 transactions created
    end

    it "deduplicates via external_id/source" do
      # Import with external_id -> publish -> check no duplicates
      # Import same external_id again -> publish -> verify update not create
    end

    it "rolls back on mapping error" do
      # Invalid account mapping -> publish -> all rolled back
    end

    it "queues background job when async=true" do
      # POST with async: true -> status: importing -> job queued
    end
  end

  describe "POST /api/v1/imports/:id/revert" do
    it "deletes created entries and rolls back" do
      # Published import -> revert -> transactions deleted
    end
  end

  describe "DELETE /api/v1/imports/:id" do
    it "destroys pending import" do
      # Pending import -> delete -> gone
    end

    it "prevents destroying published import" do
      # Published import -> delete -> 422
    end
  end
end
```

### 8. Checklist for PR

- [ ] Add routes: `update`, `destroy`, `clean`, `publish`, `revert`, `apply_template`
- [ ] Add controller actions: `update`, `clean`, `publish`, `revert`, `destroy`
- [ ] Add migration: `add_external_id_and_source_to_import_rows`
- [ ] Ensure `generate_rows_from_csv` reads `external_id`/`source` columns (already done)
- [ ] Ensure `sync_mappings` is called after column label updates (already done in web UI, needs API equivalent)
- [ ] Add request specs for all new endpoints
- [ ] Add model specs for `clean` validation logic
- [ ] Test with 441-row DSB CSV — verify all transactions import
- [ ] Test dedup: import same CSV twice, verify second import updates instead of duplicates
- [ ] Test large file handling (>1000 rows) — consider async publish for large batches
- [ ] Add `async: true` optional param to `publish` for background processing
- [ ] Security: verify `authorize_scope!(:write)` on all new actions
- [ ] Verify `X-Api-Key` scope enforcement for import lifecycle endpoints
