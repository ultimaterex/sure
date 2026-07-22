class AddExternalIdAndSourceToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :external_id, :string
    add_column :import_rows, :source, :string
  end
end
