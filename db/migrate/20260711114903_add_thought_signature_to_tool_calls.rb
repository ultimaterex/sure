# frozen_string_literal: true

class AddThoughtSignatureToToolCalls < ActiveRecord::Migration[8.1]
  def change
    # Provider reasoning signature (Gemini attaches one to each functionCall and
    # requires it echoed back on the replayed call). Nullable — only thinking
    # providers populate it. Guarded so it's safe if a sibling branch already
    # added the column on a shared database.
    return if column_exists?(:tool_calls, :thought_signature)

    add_column :tool_calls, :thought_signature, :string
  end
end
