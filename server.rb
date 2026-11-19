
#!/usr/bin/env ruby
# encoding: UTF-8
require 'webrick'
require 'webrick/httpresponse'
require 'fileutils'

require 'json'
require 'net/http'
require 'uri'
require 'base64'
require 'tempfile'
require 'ipaddr'
require 'resolv'

# Monkey-patch WEBrick::HTTPResponse#send_body_io to handle macOS sandbox sendfile Errno::EPERM
module WEBrick
  class HTTPResponse
    def send_body_io(socket)
      begin
        @body.seek(0, IO::SEEK_SET) if @body.respond_to?(:seek)
        while (chunk = @body.read(65536))
          socket.write(chunk)
          @sent_size += chunk.bytesize
        end
      ensure
        @body.close if @body.respond_to?(:close)
      end
    end
  end
end

root = File.expand_path(File.dirname(__FILE__))
env_path = File.join(root, '.env')

# Load .env configuration cleanly
config = {
  'MINHAN_API_KEY' => ENV['THUTHAO_API_KEY'] || ENV['MINHAN_API_KEY'] || ENV['GEMINI_API_KEY'] || '',
  'GEMINI_MODEL' => ENV['GEMINI_MODEL'] || 'gemini-2.5-flash',
  'PORT' => ENV['PORT'] || '8000',
  'LARK_APP_ID' => ENV['LARK_APP_ID'] || '',
  'LARK_APP_SECRET' => ENV['LARK_APP_SECRET'] || '',
  'LARK_BASE_TOKEN' => ENV['LARK_BASE_TOKEN'] || '',
  'LARK_TABLE_ID' => ENV['LARK_TABLE_ID'] || ''
}

def reload_env_config(path, cfg)
  return unless File.exist?(path)
  File.readlines(path, encoding: 'UTF-8').each do |line|
    clean = line.strip
    next if clean.empty? || clean.start_with?('#')
    key, val = clean.split('=', 2)
    cfg[key.strip] = val.strip if key && val
  end
end

reload_env_config(env_path, config)

port = (config['PORT'] || '8000').to_i

def mask_key(key)
  k = key.to_s.strip
  return 'Chưa cấu hình' if k.empty?
  'Đã kết nối Gemini'
end

def json_response(res, status_code, payload)
  res.status = status_code
  res['Content-Type'] = 'application/json; charset=UTF-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(payload)
end

THUTHAO_SYSTEM_INSTRUCTION = <<~SYS.freeze
  You are the B2B Sales Operation Agent for Thu Thảo Company.
  Execute strictly in accordance with the Thu Thảo Company B2B Sales Opportunity Process (QUY TRÌNH XỬ LÝ CƠ HỘI BÁN HÀNG B2B - THU THẢO COMPANY):
  1. Bắt đầu: Tiếp nhận yêu cầu: Tiếp nhận yêu cầu bán hàng B2B từ Excel, Lark Base, CSV, email hoặc biểu mẫu web.
  2. Phân loại & Kiểm tra thông tin: Kiểm tra tính đầy đủ của thông tin đầu vào. Quyết định: Có đủ thông tin?
     - Nếu KHÔNG: Chuyển sang nhánh "Yêu cầu KH làm rõ / bổ sung" (soạn email/tin nhắn làm rõ), dừng tính toán và quay lại bước Tiếp nhận khi có thông tin bổ sung.
     - Nếu CÓ: Chuyển sang bước 3.
  3. Tạo Hồ sơ Cơ hội & Gán người phụ trách: Cấp mã cơ hội CRM, gán chuyên viên phụ trách (Sales Rep), phân loại khách hàng & giải pháp.
  4. Lập Báo giá & Dự thảo đề xuất: Tính bảng giá, chiết khấu, dự thảo báo giá & giải pháp gửi khách hàng. Bỏ qua kiểm tra tồn kho (mặc định sẵn sàng cung ứng trọn gói).
  5. Kết thúc: Cập nhật & Theo dõi: Lưu trữ hồ sơ CRM, cập nhật pipeline theo dõi, gửi báo cáo điều hành và kích hoạt lịch theo dõi.
SYS

def call_gemini_generate(api_key, model, prompt_or_parts, expect_json = true)
  return { ok: false, status: 400, error: 'API key chưa được cấu hình' } if api_key.to_s.strip.empty?

  initial_model = model.to_s.strip
  initial_model = 'gemini-2.5-flash' if initial_model.empty?

  # Candidates cascade: always try requested model first, then auto-fallback to active studio models if deprecated or rate-limited
  candidates = [initial_model, 'gemini-3.5-flash-lite', 'gemini-3.1-flash-lite', 'gemini-3-flash-preview', 'gemini-flash-latest'].uniq

  endpoint_name = 'Google AI Studio (generativelanguage.googleapis.com)'
  parts = prompt_or_parts.is_a?(Array) ? prompt_or_parts : [{ text: prompt_or_parts.to_s }]

  body_obj = {
    contents: [
      {
        role: 'user',
        parts: parts
      }
    ],
    generationConfig: {
      temperature: 0.1
    }
  }
  body_obj[:generationConfig][:responseMimeType] = 'application/json' if expect_json
  body_json = JSON.generate(body_obj)

  last_error = nil
  last_code = 500
  effective_used = initial_model

  candidates.each do |model_name|
    url = "https://generativelanguage.googleapis.com/v1beta/models/#{URI.encode_www_form_component(model_name)}:generateContent?key=#{URI.encode_www_form_component(api_key.to_s.strip)}"
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 35

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req.body = body_json

    resp = http.request(req)
    code = resp.code.to_i
    parsed = begin
      JSON.parse(resp.body)
    rescue StandardError
      { 'raw' => resp.body.to_s[0, 500] }
    end

    if code >= 200 && code < 300
      text = parsed.dig('candidates', 0, 'content', 'parts', 0, 'text').to_s
      return {
        ok: true,
        status: code,
        endpoint: endpoint_name,
        endpointUrl: "https://generativelanguage.googleapis.com/v1beta/models/#{model_name}:generateContent",
        model: initial_model,
        effectiveModel: model_name,
        text: text
      }
    else
      err_msg = parsed.dig('error', 'message') || "HTTP #{code}"
      last_error = err_msg
      last_code = code
      effective_used = model_name
      # If 404 (model deprecated for new users) or 429 (rate/daily quota limit), cascade to next candidate
      next if code == 404 || code == 429
      break
    end
  end

  {
    ok: false,
    status: last_code,
    endpoint: endpoint_name,
    endpointUrl: "https://generativelanguage.googleapis.com/v1beta/models/#{effective_used}:generateContent",
    model: initial_model,
    effectiveModel: effective_used,
    error: last_error || "HTTP #{last_code}"
  }
rescue StandardError => e
  {
    ok: false,
    status: 502,
    endpoint: endpoint_name,
    endpointUrl: "https://generativelanguage.googleapis.com/v1beta/models/#{initial_model}:generateContent",
    model: initial_model,
    error: e.message
  }
end

mime_types = WEBrick::HTTPUtils::DefaultMimeTypes
mime_types.store 'js', 'application/javascript'
mime_types.store 'css', 'text/css'
mime_types.store 'json', 'application/json'
mime_types.store 'png', 'image/png'
mime_types.store 'jpg', 'image/jpeg'
mime_types.store 'svg', 'image/svg+xml'

server = WEBrick::HTTPServer.new(
  :Port => port,
  :DocumentRoot => root,
  :MimeTypes => mime_types,
  :BindAddress => '127.0.0.1',
  :AccessLog => [],
  :Logger => WEBrick::Log.new(nil, WEBrick::BasicLog::WARN),
  :RequestCallback => Proc.new do |_req, res|
    res['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    res['Pragma'] = 'no-cache'
    res['Expires'] = '0'
  end
)

server.mount_proc '/api/status' do |req, res|
  reload_env_config(env_path, config)
  key = config['MINHAN_API_KEY'].to_s.strip
  lark_id = config['LARK_APP_ID'].to_s.strip
  json_response(res, 200, {
    ok: true,
    configured: !key.empty?,
    maskedKey: mask_key(key),
    model: (config['GEMINI_MODEL'].to_s.empty? || config['GEMINI_MODEL'].to_s.start_with?('gemini-3')) ? 'gemini-2.5-flash' : config['GEMINI_MODEL'],
    provider: 'Google AI / Gemini API',
    larkConfigured: !lark_id.empty?,
    larkAppId: mask_key(lark_id),
    larkBaseToken: mask_key(config['LARK_BASE_TOKEN']),
    larkTableId: config['LARK_TABLE_ID'].to_s
  })
end

server.mount_proc '/api/config' do |req, res|
  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    payload = JSON.parse(req.body.to_s)
    new_key = payload['apiKey'].to_s.strip.sub(/\.+\z/, '')
    new_model = payload['model'].to_s.strip

    config['MINHAN_API_KEY'] = new_key unless new_key.empty?
    config['GEMINI_MODEL'] = new_model unless new_model.empty?
    config['LARK_APP_ID'] = payload['larkAppId'].to_s.strip if payload.key?('larkAppId')
    config['LARK_APP_SECRET'] = payload['larkAppSecret'].to_s.strip if payload.key?('larkAppSecret')
    config['LARK_BASE_TOKEN'] = payload['larkBaseToken'].to_s.strip if payload.key?('larkBaseToken')
    config['LARK_TABLE_ID'] = payload['larkTableId'].to_s.strip if payload.key?('larkTableId')

    env_lines = [
      "MINHAN_API_KEY=#{config['MINHAN_API_KEY']}",
      "GEMINI_MODEL=#{config['GEMINI_MODEL']}",
      "PORT=#{port}",
      "LARK_APP_ID=#{config['LARK_APP_ID']}",
      "LARK_APP_SECRET=#{config['LARK_APP_SECRET']}",
      "LARK_BASE_TOKEN=#{config['LARK_BASE_TOKEN']}",
      "LARK_TABLE_ID=#{config['LARK_TABLE_ID']}"
    ].join("\n") + "\n"

    File.write(env_path, env_lines)
    json_response(res, 200, {
      ok: true,
      configured: !config['MINHAN_API_KEY'].to_s.empty?,
      maskedKey: mask_key(config['MINHAN_API_KEY']),
      model: config['GEMINI_MODEL'],
      larkConfigured: !config['LARK_APP_ID'].to_s.empty?
    })
  rescue StandardError => e
    json_response(res, 400, { ok: false, error: e.message })
  end
end

server.mount_proc '/api/test' do |req, res|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  payload = begin
              JSON.parse(req.body.to_s)
            rescue StandardError
              {}
            end
  test_key = payload['apiKey'].to_s.strip
  test_key = config['MINHAN_API_KEY'] if test_key.empty?
  test_model = payload['model'].to_s.strip
  test_model = config['GEMINI_MODEL'] if test_model.empty?
  test_model = 'gemini-2.5-flash' if test_model.to_s.strip.empty?

  result = call_gemini_generate(
    test_key,
    test_model,
    'Trả lời duy nhất JSON {"status":"ok","service":"Thu Thảo B2B Agent"}',
    true
  )
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
  result[:latencyMs] = elapsed_ms
  if result[:ok] && result[:effectiveModel] && result[:effectiveModel] != result[:model]
    result[:note] = "Google AI Studio kết nối thành công qua #{result[:effectiveModel]} (tự động điều phối do #{result[:model]} ngưng cấp tài khoản mới hoặc vượt quota)."
  end
  json_response(res, 200, result)
end

audit_trail_path = File.join(root, 'audit_trail.json')
audit_mutex = Mutex.new

server.mount_proc '/api/audit-log' do |req, res|
  if req.request_method == 'GET'
    entries = audit_mutex.synchronize do
      if File.exist?(audit_trail_path)
        begin
          JSON.parse(File.read(audit_trail_path, encoding: 'UTF-8'))
        rescue StandardError
          []
        end
      else
        []
      end
    end
    next json_response(res, 200, { ok: true, count: entries.length, entries: entries })
  end

  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    payload = JSON.parse(req.body.to_s)
    total_count = 0
    audit_mutex.synchronize do
      existing = if File.exist?(audit_trail_path)
                   begin
                     JSON.parse(File.read(audit_trail_path, encoding: 'UTF-8'))
                   rescue StandardError
                     []
                   end
                 else
                   []
                 end
      existing = [] unless existing.is_a?(Array)
      existing.unshift(payload)
      existing = existing.first(500)
      File.write(audit_trail_path, JSON.pretty_generate(existing), encoding: 'UTF-8')
      total_count = existing.length
    end
    json_response(res, 200, { ok: true, savedCount: total_count, file: 'audit_trail.json' })
  rescue StandardError => e
    json_response(res, 400, { ok: false, error: e.message })
  end
end

server.mount_proc '/api/agent' do |req, res|
  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    payload = JSON.parse(req.body.to_s)
    action = payload['action'].to_s
    data = payload['data'] || {}
    model = payload['model'].to_s.strip
    model = config['GEMINI_MODEL'].to_s.strip if model.empty?
    model = 'gemini-2.5-flash' if model.empty?

    if action == 'parse_b2b_records_batch'
      rows = Array(data['rows'])
      rows = ['(File trống hoặc không có dòng dữ liệu)'] if rows.empty?

      parsed_records = []
      batch_error = nil
      rows.each_with_index do |raw_item, idx|
        raw_str = raw_item.is_a?(Hash) ? JSON.generate(raw_item) : raw_item.to_s
        row_prompt = <<~PROMPT
          # VAI TRÒ & NGUYÊN TẮC XỬ LÝ DỮ LIỆU THIẾU (ÁP DỤNG CHO TẤT CẢ CÁC BƯỚC)
          Bạn là AI Agent phân tích dữ liệu cơ hội bán hàng B2B (Thu Thảo Company).
          Thiếu thông tin KHÔNG phải lý do để dừng quy trình. Luôn chạy tiếp tới bước cuối, trường nào thiếu thì để trống (= null).

          ### Bước kiểm tra thông tin (ĐK1)
          1. Đọc file và xác định từng trường:
             - khach_hang: Tên khách hàng / công ty hoặc null
             - nvkd_phu_trach: Tên NVKD phụ trách hoặc null
             - danh_muc_san_pham: Tên sản phẩm / giải pháp hoặc null
             - so_luong: Số lượng (chỉ điền số khi file có số cụ thể) hoặc null
             - ngan_sach_du_kien: Số tiền ngân sách dự kiến (VND) hoặc null
             - thoi_han_trien_khai: Thời hạn hoặc mốc tiến độ hoặc null
             - de_nghi_chiet_khau: Số phần trăm chiết khấu (VD: 5.0). CHỈ điền 0 nếu file ghi rõ là 0 hoặc không nhắc đến giảm giá; nếu không đọc được hoặc không có thì để null hoặc 0.
          2. Mỗi trường gắn một trạng thái: "có" (tìm thấy rõ ràng trong file, ghi rõ nguồn sheet/cột/ô trong co_so) hoặc "thiếu" (không có, hoặc không đọc ra giá trị rõ ràng).
          3. Chỉ dừng hẳn trong 2 trường hợp: file rỗng/không đọc được, hoặc không có bất kỳ trường nào ở trên có dữ liệu. Ngoài ra luôn cho đi tiếp sang bước 3.
          4. Danh sách trường thiếu và câu hỏi gợi ý làm rõ với khách hàng vẫn xuất ra, nhưng chỉ để tham khảo, không chặn quy trình.

          ### Từ bước 3 trở đi
          - Trường nào "thiếu" thì giá trị = null (để trống). Tuyệt đối KHÔNG điền 0, "N/A", "-", giá trị mặc định hay số tự đoán. Số 0 chỉ dùng khi file ghi rõ là 0.
          - Bước nào cần trường bị thiếu để tính thì bỏ qua phần tính đó và để trống kết quả tương ứng. Ví dụ thiếu số lượng hoặc đơn giá thì tổng đề xuất để trống (tong_de_xuat = null), không ghi "0 đ"; thiếu ngân sách thì không đánh giá biên lợi nhuận.
          - Phần nào tính được từ dữ liệu có sẵn thì vẫn tính bình thường, không vì một trường thiếu mà bỏ cả bước.
          - Không được tự suy ra giá trị cho trường thiếu từ ví dụ mẫu, lịch sử hay file khác.

          ### Tự kiểm tra trước khi trả
          - Có trường nào thiếu mà mình đang điền số/chữ không? Nếu có thì xóa về null.
          - Mọi giá trị có dữ liệu đều truy ngược được về một ô trong file?
          - Giá trị bất thường (ví dụ chiết khấu âm, thời hạn 1 ngày cho đơn B2B) thì giữ nguyên theo file nhưng đánh dấu "cần xác nhận", không tự sửa.

          # ĐỊNH DẠNG ĐẦU RA JSON BẮT BUỘC (TRẢ VỀ DUY NHẤT 1 KHỐI JSON, KHÔNG KÈM MARKDOWN):
          {
            "khach_hang": "string | null",
            "nvkd_phu_trach": "string | null",
            "danh_muc_san_pham": "string | null",
            "so_luong": "number | null",
            "ngan_sach_du_kien": "number | null",
            "thoi_han_trien_khai": "string | null",
            "de_nghi_chiet_khau": "number | null",
            "tong_de_xuat": "number | null",
            "truong_thieu": ["nvkd_phu_trach", "danh_muc_san_pham", ...],
            "ghi_chu_kiem_toan": "Thiếu X trường, các mục liên quan để trống. Cần làm rõ với khách hàng: ...",
            "co_so": "Nguồn từng trường có dữ liệu (sheet/cột/ô)"
          }

          DỮ LIỆU ĐẦU VÀO:
          #{raw_str}
        PROMPT

        res_ai = call_gemini_generate(config['MINHAN_API_KEY'], model, row_prompt, true)
        unless res_ai[:ok]
          # Fallback conforming to Zero-Crash Policy
          parsed_records << {
            'trang_thai_file' => 'FILE_TRONG_HOAC_NHIEU',
            'du_lieu_trich_xuat' => {
              'khach_hang' => nil,
              'nguoi_phu_trach' => nil,
              'danh_muc_san_pham' => nil,
              'so_luong' => nil,
              'ngan_sach' => nil,
              'thoi_han_trien_khai' => nil,
              'de_nghi_chiet_khau' => 0.0
            },
            'danh_sach_truong_thieu' => ["Lỗi kết nối AI: #{res_ai[:error]}"],
            'ghi_chu_kiem_toan' => "Không thể kết nối Google AI Studio tại dòng #{idx + 1}. Hệ thống duy trì tính ổn định (Zero-Crash) và ghi nhận dòng chưa thể trích xuất.",
            'goi_y_cau_hoi_phan_tich' => [
              'Kiểm tra lại kết nối mạng hoặc hạn mức Gemini API key.',
              'Xác thực lại cấu trúc dòng dữ liệu đầu vào.'
            ],
            'khach_hang' => 'Khách hàng ẩn danh',
            'nguoi_phu_trach' => 'Chưa phân công',
            'danh_muc_san_pham' => nil,
            'so_luong' => nil,
            'ngan_sach' => nil,
            'thoi_han_trien_khai' => nil,
            'de_nghi_chiet_khau' => 0.0,
            'truong_con_thieu' => ["Lỗi kết nối AI: #{res_ai[:error]}"],
            'du_thong_tin' => false,
            '_rawRow' => raw_item
          }
          next
        end

        parsed_row = begin
          clean_text = res_ai[:text].gsub(/\A```json\s*|\s*```\z/, '').strip
          JSON.parse(clean_text)
        rescue StandardError => e
          {
            'trang_thai_file' => 'FILE_TRONG_HOAC_NHIEU',
            'du_lieu_trich_xuat' => {
              'khach_hang' => nil,
              'nguoi_phu_trach' => nil,
              'danh_muc_san_pham' => nil,
              'so_luong' => nil,
              'ngan_sach' => nil,
              'thoi_han_trien_khai' => nil,
              'de_nghi_chiet_khau' => 0.0
            },
            'danh_sach_truong_thieu' => ["Lỗi định dạng JSON phản hồi: #{e.message}"],
            'ghi_chu_kiem_toan' => "AI không trả về đúng định dạng JSON tại dòng #{idx + 1}.",
            'goi_y_cau_hoi_phan_tich' => [
              'Kiểm tra định dạng file nạp vào.',
              'Nhập liệu trực tiếp để tiếp tục xử lý.'
            ]
          }
        end

        ext = parsed_row['du_lieu_trich_xuat'] || {}
        parsed_row['khach_hang'] = ext['khach_hang']
        parsed_row['nguoi_phu_trach'] = ext['nguoi_phu_trach']
        parsed_row['danh_muc_san_pham'] = ext['danh_muc_san_pham']
        parsed_row['so_luong'] = ext['so_luong']
        parsed_row['ngan_sach'] = ext['ngan_sach']
        parsed_row['thoi_han_trien_khai'] = ext['thoi_han_trien_khai']
        parsed_row['de_nghi_chiet_khau'] = ext['de_nghi_chiet_khau'] || 0.0
        parsed_row['truong_con_thieu'] = parsed_row['danh_sach_truong_thieu'] || []
        parsed_row['du_thong_tin'] = (parsed_row['trang_thai_file'] == 'DAY_DU')
        parsed_row['_rawRow'] = raw_item
        parsed_records << parsed_row
      end

      next json_response(res, 200, {
        ok: true,
        records: parsed_records,
        total: parsed_records.length
      })
    end

    prompt = case action
             when 'parse_b2b_record'
               raw_data = data['rawData'] || data['rawText'] || data['record'] || JSON.generate(data)
               raw_data = '(File trống hoặc không có dòng dữ liệu)' if raw_data.to_s.strip.empty?
               <<~PROMPT
                 # VAI TRÒ & NGUYÊN TẮC XỬ LÝ DỮ LIỆU THIẾU (ÁP DỤNG CHO TẤT CẢ CÁC BƯỚC)
                 Bạn là AI Agent phân tích dữ liệu cơ hội bán hàng B2B (Thu Thảo Company).
                 Thiếu thông tin KHÔNG phải lý do để dừng quy trình. Luôn chạy tiếp tới bước cuối, trường nào thiếu thì để trống (= null).

                 ### Bước kiểm tra thông tin (ĐK1)
                 1. Đọc file và xác định từng trường:
                    - khach_hang: Tên khách hàng / công ty hoặc null
                    - nvkd_phu_trach: Tên NVKD phụ trách hoặc null
                    - danh_muc_san_pham: Tên sản phẩm / giải pháp hoặc null
                    - so_luong: Số lượng (chỉ điền số khi file có số cụ thể) hoặc null
                    - ngan_sach_du_kien: Số tiền ngân sách dự kiến (VND) hoặc null
                    - thoi_han_trien_khai: Thời hạn hoặc mốc tiến độ hoặc null
                    - de_nghi_chiet_khau: Số phần trăm chiết khấu (VD: 5.0). CHỈ điền 0 nếu file ghi rõ là 0 hoặc không nhắc đến giảm giá; nếu không đọc được hoặc không có thì để null hoặc 0.
                 2. Mỗi trường gắn một trạng thái: "có" (tìm thấy rõ ràng trong file, ghi rõ nguồn sheet/cột/ô trong co_so) hoặc "thiếu" (không có, hoặc không đọc ra giá trị rõ ràng).
                 3. Chỉ dừng hẳn trong 2 trường hợp: file rỗng/không đọc được, hoặc không có bất kỳ trường nào ở trên có dữ liệu. Ngoài ra luôn cho đi tiếp sang bước 3.
                 4. Danh sách trường thiếu và câu hỏi gợi ý làm rõ với khách hàng vẫn xuất ra, nhưng chỉ để tham khảo, không chặn quy trình.

                 ### Từ bước 3 trở đi
                 - Trường nào "thiếu" thì giá trị = null (để trống). Tuyệt đối KHÔNG điền 0, "N/A", "-", giá trị mặc định hay số tự đoán. Số 0 chỉ dùng khi file ghi rõ là 0.
                 - Bước nào cần trường bị thiếu để tính thì bỏ qua phần tính đó và để trống kết quả tương ứng. Ví dụ thiếu số lượng hoặc đơn giá thì tổng đề xuất để trống (tong_de_xuat = null), không ghi "0 đ"; thiếu ngân sách thì không đánh giá biên lợi nhuận.
                 - Phần nào tính được từ dữ liệu có sẵn thì vẫn tính bình thường, không vì một trường thiếu mà bỏ cả bước.
                 - Không được tự suy ra giá trị cho trường thiếu từ ví dụ mẫu, lịch sử hay file khác.

                 ### Tự kiểm tra trước khi trả
                 - Có trường nào thiếu mà mình đang điền số/chữ không? Nếu có thì xóa về null.
                 - Mọi giá trị có dữ liệu đều truy ngược được về một ô trong file?
                 - Giá trị bất thường (ví dụ chiết khấu âm, thời hạn 1 ngày cho đơn B2B) thì giữ nguyên theo file nhưng đánh dấu "cần xác nhận", không tự sửa.

                 # ĐỊNH DẠNG ĐẦU RA JSON BẮT BUỘC (TRẢ VỀ DUY NHẤT 1 KHỐI JSON, KHÔNG KÈM MARKDOWN):
                 {
                   "khach_hang": "string | null",
                   "nvkd_phu_trach": "string | null",
                   "danh_muc_san_pham": "string | null",
                   "so_luong": "number | null",
                   "ngan_sach_du_kien": "number | null",
                   "thoi_han_trien_khai": "string | null",
                   "de_nghi_chiet_khau": "number | null",
                   "tong_de_xuat": "number | null",
                   "truong_thieu": ["nvkd_phu_trach", "danh_muc_san_pham", ...],
                   "ghi_chu_kiem_toan": "Thiếu X trường, các mục liên quan để trống. Cần làm rõ với khách hàng: ...",
                   "co_so": "Nguồn từng trường có dữ liệu (sheet/cột/ô)"
                 }

                 DỮ LIỆU ĐẦU VÀO:
                 #{raw_data}
               PROMPT
when 'extract_and_validate'
               catalog = (data['catalog'] || []).map { |c| "- #{c['sku']}: #{c['name']} (#{c['category']})" }.join("\n")
               raw_row_json = data['rawRowJson']
               row_section = raw_row_json && !raw_row_json.to_s.strip.empty? ? "Dữ liệu dòng khách hàng dạng JSON thô:\n#{raw_row_json}\n\n" : ''
               today_str = (data['today'] && !data['today'].to_s.strip.empty?) ? data['today'].to_s : Time.now.strftime('%Y-%m-%d')
               <<~PROMPT
                 Bạn là AI Agent B2B của Công ty Thu Thảo (Hôm nay là #{today_str}). Hãy quét TOÀN BỘ các cột trong dữ liệu JSON thô của dòng khách hàng (kể cả cột Ghi chú / Mô tả / Yêu cầu / Note / Description) và nội dung yêu cầu, tự suy luận theo ngữ nghĩa để bóc tách chính xác ĐẦY ĐỦ MỌI HẠNG MỤC dưới dạng JSON thuần (không markdown) theo đúng schema sau:
                 {
                   "ten_khach_hang": "Tên khách hàng / Tên công ty tìm được (tuyệt đối KHÔNG lấy mã số ID thuần số như 977966899 nếu có tên công ty/khách hàng) hoặc null",
                   "danh_muc_san_pham": "Liệt kê ĐẦY ĐỦ tất cả các tên sản phẩm tìm được cách nhau bởi dấu chấm phẩy (;) (VD: 'Sản phẩm A; Sản phẩm B')",
                   "so_luong": số_nguyên_TỔNG_số_lượng_tất_cả_các_thiết_bị_cộng_lại_hoặc_null,
                   "ngan_sach": số_tiền_VND_đã_quy_đổi_chính_xác_hoặc_null,
                   "thoi_han_trien_khai": "Mốc thời gian hoặc số ngày triển khai tìm được (VD: '5 ngày', '15 ngày', 'trong tuần này', 'tháng tới', 'Q4', 'gấp', '2026-12-15') hoặc null",
                   "de_nghi_chiet_khau": số_phần_trăm_hoặc_0,
                   "nguoi_phu_trach": "Họ tên nhân viên / người phụ trách (tuyệt đối KHÔNG lấy số tiền, doanh số hay mã số như 24450000) hoặc null",
                   "items": [
                     {
                       "sku": "Mã SKU khớp nhất trong danh mục Thu Thảo hoặc MA-CUSTOM-01",
                       "name": "Tên sản phẩm đầy đủ",
                       "qty": số_lượng_của_hạng_mục_này
                     }
                   ],
                   "category": "Hạ tầng & Bảo mật" | "Thiết bị Văn phòng" | "Phần mềm & Dịch vụ",
                   "summaryNote": "tóm tắt 1 câu"
                 }
                 Quy tắc bắt buộc khi bóc tách:
                 1. BẮT BUỘC bóc tách ĐỦ TẤT CẢ các hạng mục sản phẩm vào mảng "items". TUYỆT ĐỐI KHÔNG bỏ sót hạng mục nào!
                    - Ví dụ: Yêu cầu '25 Sản phẩm A và 8 Sản phẩm B' thì mảng items BẮT BUỘC có 2 phần tử:
                      [{"sku": "SKU-01", "name": "Sản phẩm A", "qty": 25}, {"sku": "SKU-02", "name": "Sản phẩm B", "qty": 8}]
                 2. Trường "so_luong" BẮT BUỘC là TỔNG số lượng của TẤT CẢ các hạng mục cộng lại (VD: 25 Switch + 8 Server = 33 thiết bị).
                 3. Mặc định chiết khấu = 0%: Nếu toàn bộ dữ liệu khách hàng KHÔNG đề cập đến chiết khấu / giảm giá / discount / CK / % giảm, BẮT BUỘC trả về "de_nghi_chiet_khau": 0 (TUYỆT ĐỐI không trả về null).
                 4. Chuẩn hoá Ngân sách về số nguyên VND:
                    - '3.1 tỷ' hoặc '3,1 tỷ' hoặc '3.1 tỷ VND' -> 3100000000 (Ba tỷ một trăm triệu VND, TUYỆT ĐỐI không nhầm thành 31 tỷ hay 31000000000).
                    - '1.5 tỷ' -> 1500000000.
                    - '3100 triệu' -> 3100000000.
                    - '500tr' -> 500000000.
                    - '450 triệu' -> 450000000.
                    - '24.45 triệu' -> 24450000.
                 5. Suy luận Thời hạn từ TẤT CẢ các cột (kể cả Ghi chú, Mô tả, Note, SLA...): Quét tìm mọi mốc thời gian ('5 ngày', '14 ngày', 'trong tuần này', 'gấp', 'hỏa tốc'...) để gán vào "thoi_han_trien_khai".
                 6. Tên khách hàng (ten_khach_hang): Ưu tiên cột Tên khách hàng / Tên công ty / Company Name / Client Name; tuyệt đối không lấy dãy số ID (ví dụ 977966899) làm tên khách hàng nếu trong dữ liệu có tên công ty hoặc tên khách.
                 7. Người phụ trách (nguoi_phu_trach): Tuyệt đối không nhầm cột doanh số/giá trị/Sales Amount (ví dụ 24450000) thành nguoi_phu_trach. Nếu chỉ thấy số thì trả về null.
                 Danh mục sản phẩm chuẩn Thu Thảo:
                 #{catalog}

                 #{row_section}Nội dung yêu cầu khách hàng:
                 #{data['rawText']}
               PROMPT
             when 'polish_email'
               <<~PROMPT
                 Bạn là chuyên viên B2B Công ty Thu Thảo. Hãy viết bản nháp email tiếng Việt chuyên nghiệp, lịch sự dựa trên dữ liệu sau (trả JSON {"email": "nội dung email"}):
                 Khách hàng: #{data['company']}
                 Loại email: #{data['kind']}
                 Thông tin chi tiết: #{data['context']}
               PROMPT
             when 'generate_clarification_email'
               company = (data['company'] && !data['company'].to_s.strip.empty?) ? data['company'].to_s : 'Quý Khách hàng'
               contact = (data['contact'] || '').to_s
               understood = (data['understood'] && !data['understood'].to_s.strip.empty?) ? data['understood'].to_s : 'nhu cầu thiết bị ban đầu'
               missing = Array(data['missingFields']).join(', ')
               owner = (data['owner'] && !data['owner'].to_s.strip.empty?) ? data['owner'].to_s : 'Thu Thảo'
               channel = (data['channel'] || 'Email').to_s
               <<~PROMPT
                 Bạn là AI Agent B2B của Công ty Thu Thảo Technology (NVKD phụ trách: #{owner}).
                 Hãy viết một email bằng tiếng Việt ngắn gọn, chuyên nghiệp, lịch sự để gửi khách hàng yêu cầu làm rõ các thông tin còn thiếu cho việc lập báo giá B2B.

                 Dữ liệu yêu cầu:
                 - Tên khách hàng / Đơn vị: #{company}
                 - Kênh tiếp nhận: #{channel}
                 - Những gì Thu Thảo đã hiểu: #{understood}
                 - Danh sách trường còn thiếu / cần làm rõ: #{missing}
                 - NVKD phụ trách: #{owner}

                 Cấu trúc email bắt buộc gồm đúng 6 phần:
                 1) Tiêu đề rõ ràng: Có nhắc tên khách hàng và mục đích báo giá (VD: [Thu Thảo Technology] Yêu cầu làm rõ thông tin báo giá - Kính gửi #{company}).
                 2) Lời chào lịch sự + Cảm ơn Quý khách hàng/Quý đối tác đã gửi yêu cầu cho Thu Thảo Technology.
                 3) Tóm tắt ngắn gọn 1-2 câu những gì Thu Thảo đã tiếp nhận được (#{understood}) để khách xác nhận.
                 4) Danh sách câu hỏi đánh số (1., 2., ...), MỖI trường thiếu ĐÚNG MỘT CÂU HỎI kèm gợi ý cách trả lời:
                    - Nếu thiếu chủng loại/model: hỏi rõ mã hiệu, model thiết bị chi tiết.
                    - Nếu thiếu số lượng: hỏi số lượng cụ thể từng hạng mục.
                    - Nếu thiếu ngân sách: hỏi ngân sách dự kiến hoặc hạn mức tài chính tối đa của đơn vị.
                    - Nếu thiếu thời hạn: hỏi thời hạn mong muốn nhận hàng hoặc hoàn thành triển khai.
                    TUYỆT ĐỐI CHỈ hỏi những gì còn thiếu (#{missing}), KHÔNG hỏi lại thông tin đã có.
                 5) Lời mời phản hồi: Đề nghị khách hàng phản hồi sớm trong vòng 24 giờ để kịp tiến độ báo giá và giữ chỗ thiết bị kho.
                 6) Chữ ký: #{owner} - Chuyên viên Tư vấn Giải pháp B2B, Thu Thảo Technology.

                 Trả về định dạng JSON thuần (không dùng markdown hay ký tự bao quanh ngoài JSON) theo đúng schema:
                 {
                   "subject": "Tiêu đề email",
                   "body": "Nội dung email đầy đủ",
                   "email": "Tiêu đề: [Tiêu đề]\\n\\n[Nội dung email đầy đủ kèm chữ ký]"
                 }
               PROMPT
             when 'analyze_dataset'
               headers = Array(data['headers']).join(', ')
               sample_rows = JSON.generate(Array(data['sampleRows']).first(5))
               <<~PROMPT
                 Bạn là Chuyên gia Dữ liệu & AI Agent của Công ty Thu Thảo. Hãy phân tích tiêu đề cột và dữ liệu mẫu từ file (Excel / Lark / CSV / JSON / TSV) dưới đây và ánh xạ chuẩn xác sang schema xử lý cơ hội & doanh thu B2B dưới dạng JSON thuần.
                 Quy tắc ánh xạ linh hoạt đa ngôn ngữ (tiếng Việt, tiếng Anh, viết tắt):
                 - "company": Tìm cột khách hàng (Buyer, Customer, Client, KH, Tên KH, Đối tác, Đơn vị, Company Name...). Tuyệt đối KHÔNG chọn cột ID/Mã KH thuần số như 977966899.
                 - "product": Tìm cột sản phẩm / giải pháp (Product, Solution, Item, Hạng mục, Gói thiết bị, Tên SP, SP, Package, Dịch vụ...).
                 - "qty": Tìm cột số lượng (Quantity, Units, Volume, SL, Count, Pcs...).
                 - "budget": Tìm cột ngân sách / dự trù / kinh phí (Budget, Kinh phí, Dự toán, Dự trù, NS...).
                 - "revenue": Tìm cột doanh thu / thành tiền / giá trị (Amount, Total, Total Amount, Doanh thu, Thành tiền, Giá trị...).
                 - "cost": Tìm cột chi phí / giá vốn (Cost, Chi phí, Giá vốn...).
                 - "discount": Tìm cột chiết khấu (Discount, Rebate, CK, CK%, Chiết khấu, % giảm giá, Ưu đãi...).
                 - "days": Tìm cột thời hạn / tiến độ / hạn giao (Timeline, Delivery, Deadline, Due Date, Thời hạn, Hạn, Hạn hoàn thành, Số ngày, SLA...).
                 - "owner": Tìm cột người phụ trách / NVKD (Sales Rep, Sales Owner, PIC, NVKD, Account Manager, Chuyên viên phụ trách, Người phụ trách). TUYỆT ĐỐI KHÔNG chọn cột số tiền, doanh số hay giá trị (như Sales Amount, Doanh số, 24450000). Nếu chỉ thấy số tiền hoặc không có cột NVKD thì trả về null.
                 - Cột nào không tìm thấy khớp thì để null.
                 Schema JSON trả về:
                 {
                   "datasetKind": "opportunities" | "revenue_report" | "catalog" | "mixed",
                   "recommendedGroupField": "owner" | "category" | "channel" | "statusLabel" | "priorityTier",
                   "datasetSummary": "Mô tả ngắn gọn 1 câu file này chứa gì",
                   "columnMap": {
                     "company": "tên cột khách hàng hoặc null",
                     "contact": "tên cột email/liên hệ hoặc null",
                     "channel": "tên cột kênh/nguồn hoặc null",
                     "owner": "tên cột NVKD phụ trách (tuyệt đối không lấy cột số tiền) hoặc null",
                     "category": "tên cột nhóm sản phẩm/danh mục hoặc null",
                     "product": "tên cột sản phẩm hoặc null",
                     "qty": "tên cột số lượng hoặc null",
                     "budget": "tên cột ngân sách hoặc null",
                     "revenue": "tên cột doanh thu/giá trị/thành tiền hoặc null",
                     "cost": "tên cột chi phí/giá vốn hoặc null",
                     "discount": "tên cột chiết khấu % hoặc null",
                     "days": "tên cột thời hạn/số ngày hoặc null",
                     "status": "tên cột trạng thái hoặc null",
                     "rawText": "tên cột mô tả yêu cầu chi tiết hoặc null"
                   }
                 }
                 Danh sách cột (headers): #{headers}
                 5 dòng dữ liệu mẫu: #{sample_rows}
               PROMPT
             when 'executive_report'
               <<~PROMPT
                 Bạn là agent ở BƯỚC 5 (bước cuối) trong quy trình xử lý cơ hội bán hàng B2B của Thu Thảo Company. Nhiệm vụ: tổng hợp toàn bộ kết quả các bước trước thành báo cáo dashboard và đề xuất giải pháp cho doanh nghiệp.

                 ## Đầu vào
                 File dữ liệu gốc của lần chạy này và kết quả các bước 1-4 (hồ sơ cơ hội, người phụ trách, thẩm định tồn kho và giá, báo giá, dự thảo đề xuất). Mỗi file có cấu trúc khác nhau, không giả định cấu trúc từ lần chạy trước.
                 Dữ liệu đầu vào:
                 #{JSON.generate(data)}

                 ## Nguyên tắc bắt buộc
                 1. Chỉ dùng dữ liệu có thật trong file và kết quả các bước trước. Không bịa số, không lấy từ ví dụ mẫu hay lịch sử.
                 2. Trường nào thiếu thì để null, hiển thị "(Để trống)". Không điền 0, "N/A" hay số đoán. Số 0 chỉ dùng khi file ghi rõ là 0.
                 3. Biểu đồ hoặc chỉ số nào không đủ dữ liệu để tính thì để null và ghi lý do, không vẽ số giả.
                 4. Giá trị bất thường (chiết khấu âm, thời hạn triển khai quá ngắn, ngân sách thấp hơn giá niêm yết...) giữ nguyên theo file nhưng đưa vào mục cảnh báo "cần xác nhận".
                 5. Mọi con số truy ngược được về sheet/cột/ô cụ thể trong file gốc.

                 ## Cách làm
                 Bước A: Đánh giá độ đầy đủ dữ liệu: bao nhiêu trường có, bao nhiêu thiếu, trường nào thiếu ảnh hưởng tới phần nào của báo cáo.
                 Bước B: Tính các chỉ số có thể tính từ dữ liệu sẵn có (tổng giá trị niêm yết, % chiết khấu, biên lợi nhuận, so với ngân sách, thời gian triển khai, tồn kho so với số lượng cần). Chỉ số nào thiếu đầu vào thì để null.
                 Bước C: Nhận diện rủi ro và cơ hội, mỗi mục kèm bằng chứng từ dữ liệu.
                 Bước D: Viết đề xuất giải pháp dựa trên bằng chứng ở bước C.

                 ## Quy tắc viết đề xuất giải pháp
                 - Mỗi đề xuất phải có: vấn đề, căn cứ (số liệu hoặc trường dữ liệu cụ thể), hành động đề xuất, người phụ trách gợi ý (NVKD, Vận hành, Trưởng phòng), mức ưu tiên (cao/trung bình/thấp), thời hạn gợi ý.
                 - Dữ liệu thiếu thì đề xuất đầu tiên luôn là làm rõ với khách hàng, nêu đích danh trường cần bổ sung. Không đưa ra phân tích về phần thiếu như thể đã có số.
                 - Đề xuất phải cụ thể cho cơ hội này. Không viết lời khuyên chung chung kiểu "nâng cao chất lượng dịch vụ".
                 - Tối đa 5 đề xuất, sắp theo mức ưu tiên. Mỗi đề xuất viết gọn 2-3 câu, văn xuôi, không bảng.
                 - Nếu có vượt thẩm quyền hoặc cần chiết khấu đặc biệt, nêu rõ cần Trưởng phòng duyệt và lý do kèm con số.

                 ## Đầu ra: JSON để dashboard hiển thị
                 {
                   "tong_quan": {
                     "ma_co_hoi": ..., "khach_hang": ..., "nvkd_phu_trach": ...,
                     "trang_thai": "...", "ngay_theo_doi_tiep": ...
                   },
                   "do_day_du_du_lieu": {
                     "so_truong_co": 0, "so_truong_thieu": 0, "ty_le_day_du_pct": 0,
                     "truong_thieu": ["..."], "anh_huong": "Phần nào của báo cáo bị ảnh hưởng"
                   },
                   "chi_so_chinh": [
                     {"ten": "Tổng giá trị niêm yết", "gia_tri": null, "don_vi": "VND", "ghi_chu": "Lý do nếu để trống"}
                   ],
                   "du_lieu_bieu_do": [
                     {"ten": "...", "loai": "bar|line|pie", "nhan": [], "gia_tri": [], "ghi_chu": "null nếu không đủ dữ liệu"}
                   ],
                   "canh_bao": [
                     {"muc_do": "cao|trung_binh|thap", "noi_dung": "...", "can_cu": "..."}
                   ],
                   "rui_ro_va_co_hoi": {
                     "rui_ro": [{"noi_dung": "...", "can_cu": "..."}],
                     "co_hoi": [{"noi_dung": "...", "can_cu": "..."}]
                   },
                   "de_xuat_giai_phap": [
                     {
                       "uu_tien": "cao|trung_binh|thap",
                       "van_de": "...", "can_cu": "...", "hanh_dong": "...",
                       "nguoi_phu_trach": "...", "thoi_han": "..."
                     }
                   ],
                   "nhanh_quy_trinh": "Chuyển Trưởng phòng duyệt | Kết thúc, cập nhật và theo dõi",
                   "co_so": "File/sheet/cột/ô đã dùng, giả định đã đặt, chỗ không chắc"
                 }
                 Giữ đủ mọi trường trong JSON kể cả trường null. Chỉ trả JSON, không thêm chữ ngoài JSON.
                PROMPT
             else
               next json_response(res, 400, { ok: false, error: "Unsupported action: #{action}" })
             end

    res_ai = call_gemini_generate(config['MINHAN_API_KEY'], model, prompt, true)
    if res_ai[:ok]
      parsed_json = begin
        JSON.parse(res_ai[:text].gsub(/\A```json\s*|\s*```\z/, '').strip)
      rescue StandardError
        nil
      end

      if action == 'parse_b2b_record' && parsed_json.is_a?(Hash)
        ext = parsed_json['du_lieu_trich_xuat'] || {}
        parsed_json['khach_hang'] ||= ext['khach_hang']
        parsed_json['nvkd_phu_trach'] ||= ext['nvkd_phu_trach'] || ext['nguoi_phu_trach'] || parsed_json['nguoi_phu_trach']
        parsed_json['danh_muc_san_pham'] ||= ext['danh_muc_san_pham']
        parsed_json['so_luong'] = parsed_json['so_luong'] || ext['so_luong']
        parsed_json['ngan_sach_du_kien'] = parsed_json['ngan_sach_du_kien'] || parsed_json['ngan_sach'] || ext['ngan_sach']
        parsed_json['thoi_han_trien_khai'] ||= ext['thoi_han_trien_khai']
        parsed_json['de_nghi_chiet_khau'] = parsed_json['de_nghi_chiet_khau'] || ext['de_nghi_chiet_khau']
        parsed_json['truong_thieu'] ||= parsed_json['danh_sach_truong_thieu'] || parsed_json['truong_con_thieu'] || []
        parsed_json['ghi_chu_kiem_toan'] ||= parsed_json['ghi_chu_kiem_toan'] || ''
        parsed_json['co_so'] ||= parsed_json['co_so'] || 'Dữ liệu đầu vào'
      end

      json_response(res, 200, {
        ok: true,
        endpoint: res_ai[:endpoint],
        model: res_ai[:model],
        data: parsed_json,
        rawText: res_ai[:text]
      })
    else
      json_response(res, 200, res_ai)
    end
  rescue StandardError => e
    json_response(res, 400, { ok: false, error: e.message })
  end
end

server.mount_proc '/api/parse-file' do |req, res|
  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    payload = JSON.parse(req.body.to_s)
    file_name = payload['fileName'].to_s
    mime_type = payload['mimeType'].to_s
    base64_data = payload['base64Data'].to_s
    text_content = payload['textContent'].to_s
    catalog = Array(payload['catalog']).map { |c| "- #{c['sku']}: #{c['name']} (#{c['category']})" }.join("\n")
    ext = File.extname(file_name).downcase

    # Extract text for Word/RTF binary docs on macOS using textutil
    if text_content.strip.empty? && !base64_data.empty? && %w[.docx .doc .rtf .odt].include?(ext)
      raw_bytes = Base64.decode64(base64_data)
      tmp = Tempfile.new(['thuthao_upload', ext])
      begin
        tmp.binmode
        tmp.write(raw_bytes)
        tmp.close
        extracted = IO.popen(['/usr/bin/textutil', '-convert', 'txt', '-stdout', tmp.path], &:read)
        text_content = extracted.to_s.force_encoding('UTF-8').scrub
      ensure
        tmp.close! unless tmp.closed?
        tmp.unlink if File.exist?(tmp.path)
      end
    end

    instruction = <<~PROMPT
      Bạn là AI Agent B2B Thu Thảo Company. Hãy đọc toàn bộ nội dung tệp "#{file_name}" và trích xuất danh sách TẤT CẢ các dự án / yêu cầu / đơn hàng B2B có trong tệp để đưa vào Quy trình Xử lý Cơ hội Bán hàng B2B (Thu Thảo Company).
      Trả về duy nhất JSON thuần (không markdown):
      {
        "datasetSummary": "Tóm tắt nội dung tệp 1 câu",
        "recommendedGroupField": "owner" | "category" | "priorityTier" | "projectType" | "channel",
        "records": [
          {
            "company": "Tên khách hàng / công ty",
            "contact": "Email hoặc SĐT nếu có",
            "channel": "Email" | "Lark" | "Excel" | "PDF/Word",
            "owner": "Tên NVKD phụ trách hoặc để trống",
            "category": "Hạ tầng & Bảo mật" | "Thiết bị Văn phòng" | "Phần mềm & Dịch vụ",
            "projectType": "Loại dự án (VD: Hạ tầng Server, Mở rộng Văn phòng, Chuyển đổi số ERP, Bảo mật...)",
            "priorityTier": "VIP" | "Hạng A" | "Hạng B" | "Hạng C",
            "product": "Tên sản phẩm / hạng mục chính",
            "qty": số_lượng_số_nguyên_hoặc_0,
            "budget": ngân_sách_VND_số_nguyên_hoặc_0,
            "revenue": doanh_thu_nếu_có_hoặc_0,
            "cost": chi_phí_nếu_có_hoặc_0,
            "discount": chiết_khấu_phần_trăm_hoặc_null,
            "days": số_ngày_triển_khai_hoặc_0,
            "rawText": "Mô tả đầy đủ yêu cầu của dòng này để kiểm tra 5 trường ở Bước 2"
          }
        ]
      }
      Danh mục sản phẩm chuẩn Thu Thảo:
      #{catalog}
    PROMPT

    parts = if !text_content.strip.empty?
              [{ text: "#{instruction}\n\nNỘI DUNG TỆP:\n#{text_content[0, 30000]}" }]
            elsif !base64_data.empty? && (ext == '.pdf' || mime_type.start_with?('image/'))
              effective_mime = ext == '.pdf' ? 'application/pdf' : mime_type
              [
                { text: instruction },
                { inlineData: { mimeType: effective_mime, data: base64_data } }
              ]
            else
              next json_response(res, 200, { ok: false, error: 'Định dạng tệp chưa có nội dung đọc được', extractedText: '' })
            end

    res_ai = call_gemini_generate(config['MINHAN_API_KEY'], config['GEMINI_MODEL'], parts, true)
    if res_ai[:ok]
      parsed_json = begin
        JSON.parse(res_ai[:text].gsub(/\A```json\s*|\s*```\z/, '').strip)
      rescue StandardError
        nil
      end
      json_response(res, 200, {
        ok: true,
        endpoint: res_ai[:endpoint],
        model: res_ai[:model],
        extractedText: text_content[0, 4000],
        data: parsed_json
      })
    else
      json_response(res, 200, { ok: false, error: res_ai[:error], extractedText: text_content[0, 4000] })
    end
  rescue StandardError => e
    json_response(res, 400, { ok: false, error: e.message })
  end
end

def safe_public_http_uri?(uri)
  return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  host = uri.host.to_s.strip
  return false if host.empty? || host.downcase == 'localhost'

  addrs = Resolv.getaddresses(host)
  return false if addrs.empty?

  blocked_ranges = [
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('::1/128'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10')
  ]
  addrs.none? do |addr_str|
    ip = IPAddr.new(addr_str)
    blocked_ranges.any? { |net| net.include?(ip) }
  end
rescue StandardError
  false
end

def normalize_sheet_export_url(raw_url)
  u = raw_url.to_s.strip
  if u =~ %r{https?://docs\.google\.com/spreadsheets/d/([a-zA-Z0-9_-]+)}
    sheet_id = Regexp.last_match(1)
    gid = u =~ /gid=(\d+)/ ? Regexp.last_match(1) : nil
    base = "https://docs.google.com/spreadsheets/d/#{sheet_id}/export?format=csv"
    return gid ? "#{base}&gid=#{gid}" : base
  end
  u
end

server.mount_proc '/api/fetch-url' do |req, res|
  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    payload = JSON.parse(req.body.to_s)
    raw_url = payload['url'].to_s.strip
    next json_response(res, 400, { ok: false, error: 'Thiếu đường dẫn URL' }) if raw_url.empty?

    target_url = normalize_sheet_export_url(raw_url)
    current_uri = URI.parse(target_url)
    unless safe_public_http_uri?(current_uri)
      next json_response(res, 400, { ok: false, error: 'URL không hợp lệ hoặc thuộc mạng nội bộ không được phép' })
    end

    response = nil
    3.times do
      http = Net::HTTP.new(current_uri.host, current_uri.port)
      http.use_ssl = current_uri.is_a?(URI::HTTPS)
      http.open_timeout = 8
      http.read_timeout = 15

      get_req = Net::HTTP::Get.new(current_uri.request_uri)
      get_req['User-Agent'] = 'ThuThao-B2B-Agent/1.0'
      response = http.request(get_req)

      if response.is_a?(Net::HTTPRedirection) && response['location']
        next_uri = URI.join(current_uri.to_s, response['location'])
        unless safe_public_http_uri?(next_uri)
          next json_response(res, 400, { ok: false, error: 'Redirect tới địa chỉ không hợp lệ' })
        end
        current_uri = next_uri
      else
        break
      end
    end

    code = response ? response.code.to_i : 0
    if code >= 200 && code < 300
      body_utf8 = response.body.to_s.force_encoding('UTF-8').scrub[0, 150_000]
      json_response(res, 200, {
        ok: true,
        resolvedUrl: current_uri.to_s,
        contentType: response['content-type'].to_s,
        content: body_utf8
      })
    else
      json_response(res, 200, { ok: false, error: "Không tải được dữ liệu từ link (HTTP #{code}). Nếu là Google Sheets / Lark, hãy bật quyền xem công khai." })
    end
  rescue StandardError => e
    json_response(res, 400, { ok: false, error: e.message })
  end
end

server.mount_proc '/api/lark/fetch' do |req, res|
  unless req.request_method == 'POST'
    next json_response(res, 405, { ok: false, error: 'Method Not Allowed' })
  end

  begin
    reload_env_config(env_path, config)
    payload = JSON.parse(req.body.to_s)
    raw_url = payload['url'].to_s.strip
    app_token = payload['appToken'].to_s.strip
    table_id = payload['tableId'].to_s.strip

    if !raw_url.empty?
      if raw_url =~ %r{/base/([a-zA-Z0-9_-]+)}
        app_token = Regexp.last_match(1) if app_token.empty?
      end
      if raw_url =~ /[?&]table=([a-zA-Z0-9_-]+)/
        table_id = Regexp.last_match(1) if table_id.empty?
      end
    end

    app_token = config['LARK_BASE_TOKEN'] if app_token.empty? && !config['LARK_BASE_TOKEN'].to_s.empty?
    table_id = config['LARK_TABLE_ID'] if table_id.empty? && !config['LARK_TABLE_ID'].to_s.empty?

    app_id = config['LARK_APP_ID'].to_s.strip
    app_secret = config['LARK_APP_SECRET'].to_s.strip

    if app_id.empty? || app_secret.empty?
      next json_response(res, 200, {
        ok: false,
        error: 'Chưa cấu hình LARK_APP_ID / LARK_APP_SECRET trong file .env. Bạn có thể cập nhật .env hoặc tải tệp CSV xuất từ Lark Base lên thay thế.',
        fallbackToCsv: true
      })
    end

    if app_token.empty? || table_id.empty?
      next json_response(res, 200, {
        ok: false,
        error: 'Thiếu Base Token hoặc Table ID của Lark Base. Vui lòng nhập link Lark Base hoặc điền Base Token & Table ID.',
        fallbackToCsv: true
      })
    end

    token_endpoints = [
      'https://open.larksuite.com/open-apis/auth/v3/tenant_access_token/internal',
      'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal'
    ]
    tenant_token = nil
    token_err = nil

    token_endpoints.each do |t_url|
      uri = URI.parse(t_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 8
      http.read_timeout = 12

      req_tok = Net::HTTP::Post.new(uri.request_uri)
      req_tok['Content-Type'] = 'application/json'
      req_tok.body = JSON.generate({ app_id: app_id, app_secret: app_secret })

      begin
        resp = http.request(req_tok)
        parsed = JSON.parse(resp.body)
        if parsed['code'] == 0 && parsed['tenant_access_token']
          tenant_token = parsed['tenant_access_token']
          break
        else
          token_err = parsed['msg'] || "HTTP #{resp.code}"
        end
      rescue StandardError => e
        token_err = e.message
      end
    end

    unless tenant_token
      next json_response(res, 200, {
        ok: false,
        error: "Xác thực Lark Open API không thành công: #{token_err}. Bạn có thể tải file CSV export thay thế.",
        fallbackToCsv: true
      })
    end

    records_url = "https://open.larksuite.com/open-apis/bitable/v1/apps/#{app_token}/tables/#{table_id}/records?page_size=100"
    uri_rec = URI.parse(records_url)
    http_rec = Net::HTTP.new(uri_rec.host, uri_rec.port)
    http_rec.use_ssl = true
    http_rec.open_timeout = 8
    http_rec.read_timeout = 15

    get_req = Net::HTTP::Get.new(uri_rec.request_uri)
    get_req['Authorization'] = "Bearer #{tenant_token}"
    get_req['Content-Type'] = 'application/json'

    resp_rec = http_rec.request(get_req)
    parsed_rec = JSON.parse(resp_rec.body)

    if parsed_rec['code'] == 0 && parsed_rec['data'] && parsed_rec['data']['items']
      items = parsed_rec['data']['items']
      rows = items.map do |it|
        fields = it['fields'] || {}
        row = { '_sheetName' => "Lark Base [#{table_id}]" }
        fields.each { |k, v| row[k] = v }
        row
      end
      json_response(res, 200, {
        ok: true,
        sourceName: "Lark Base (#{app_token[0, 8]}...)",
        records: rows,
        total: rows.length
      })
    else
      err_msg = parsed_rec['msg'] || "HTTP #{resp_rec.code}"
      json_response(res, 200, {
        ok: false,
        error: "Lỗi đọc dữ liệu Lark Bitable: #{err_msg}. Bạn có thể tải file CSV export từ Lark Base thay thế.",
        fallbackToCsv: true
      })
    end
  rescue StandardError => e
    json_response(res, 200, {
      ok: false,
      error: "Lỗi kết nối Lark Open API: #{e.message}. Bạn có thể tải file CSV export từ Lark Base thay thế.",
      fallbackToCsv: true
    })
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "========================================================"
puts "  THU THẢO COMPANY - B2B AI AGENT SALES SYSTEM"
puts "  Server dang chay tai: http://localhost:#{port}"
puts "  API Key da gan: #{mask_key(config['MINHAN_API_KEY'])} (#{config['GEMINI_MODEL']})"
puts "  Nhan Ctrl + C de dung server"
puts "========================================================"

system("open http://localhost:#{port} >/dev/null 2>&1 &") unless ENV['NO_OPEN'] == '1'

server.start
