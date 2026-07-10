# frozen_string_literal: true

class AddThoughtSignatureToToolCalls < ActiveRecord::Migration[8.1]
  def change
    # Provider reasoning signature (e.g. Gemini's OpenAI-compat
    # extra_content.google.thought_signature) that must be replayed on
    # subsequent tool_calls. Nullable — only thinking providers populate it.
    add_column :tool_calls, :thought_signature, :string
  end
end
