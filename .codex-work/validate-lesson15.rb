require 'digest'

root = Dir.pwd
note_path = File.join(root, 'CurseHunter/6817/Бланк вопросов и заданий.md')
body = File.read(note_path, encoding: 'UTF-8')
abort 'missing frontmatter' unless body.start_with?("---\n")

parts = body.split(/^---\s*$\n?/, 3)
frontmatter = parts[1]
keys = frontmatter.lines.map { |line| line[/^([^\s][^:]*):\s*/, 1] }.compact
allowed = %w[aliases tags статус]
bad = keys.uniq - allowed

embeds = body.scan(/!\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]/).flatten
missing = embeds.uniq.reject { |rel| File.exist?(File.join(root, rel)) }

lesson = body[/^## Урок 15\..*?(?=^## Источники\s*$)/m]
abort 'lesson 15 not found' unless lesson

expected = (106..118).map(&:to_s)
refs = lesson.scan(%r{Кадры/(\d{3})-}).flatten
frame_dir = File.join(root, '90 Вложения/CurseHunter/6817/Кадры')
files = Dir.children(frame_dir).grep(/^(10[6-9]|11[0-8])-/).sort
digests = files.map { |file| Digest::SHA256.file(File.join(frame_dir, file)).hexdigest }

hard_patterns = {
  'thus' => /таким образом/i,
  'conclusion' => /в заключени[еи]/i,
  'important_note' => /важно отметить/i,
  'it_should_be_noted' => /следует отметить/i,
  'modern_world' => /в современном мире/i,
  'chatbot' => /как (?:языковая модель|ИИ|искусственный интеллект)/i,
  'mojibake' => /(?:Ã.|Â.|Ð.|Ñ.)/
}
hits = hard_patterns.map do |name, regex|
  match = lesson.match(regex)
  [name, match[0]] if match
end.compact

puts "frontmatter_keys=#{keys.uniq.join(',')}"
puts "frontmatter_bad=#{bad.inspect}"
puts "embeds=#{embeds.length} unique=#{embeds.uniq.length} missing=#{missing.length}"
puts "fences=#{body.scan(/^```/).length}"
puts "sources_headings=#{body.scan(/^## Источники\s*$/).length}"
puts "lesson15_lines=#{lesson.lines.length} lesson15_words=#{lesson.scan(/[[:alnum:]_А-Яа-яЁё*]+/).length}"
puts "lesson15_frame_refs=#{refs.sort.join(',')}"
puts "lesson15_files=#{files.length} distinct_sha256=#{digests.uniq.length}"
puts "humanizer_hard_hits=#{hits.inspect}"
puts "utf8_valid=#{body.valid_encoding?}"

abort "bad frontmatter: #{bad.inspect}" unless bad.empty?
abort "missing embeds: #{missing.inspect}" unless missing.empty?
abort 'unbalanced code fences' unless body.scan(/^```/).length.even?
abort 'wrong sources heading count' unless body.scan(/^## Источники\s*$/).length == 1
abort "wrong lesson frame refs: #{refs.inspect}" unless refs.sort == expected
abort "wrong lesson frame file count: #{files.inspect}" unless files.length == 13
abort 'duplicate lesson frame images' unless digests.uniq.length == 13
abort "humanizer/artifact hits: #{hits.inspect}" unless hits.empty?
abort 'invalid UTF-8' unless body.valid_encoding?
