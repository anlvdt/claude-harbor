# Áp dụng bài học AI Switch vào Harbor

Phạm vi đã được người dùng yêu cầu triển khai từ báo cáo nghiên cứu: protocol/lỗi có cấu trúc, trạng thái thao tác và sức khỏe profile, kiểm tra bản phát hành. Giữ AppKit/Python, dữ liệu và cơ chế khóa/journal hiện có. Không thêm chuyển provider, nhóm chia sẻ mới hoặc cập nhật tự động.

Thiết kế: CLI mặc định giữ định dạng cũ; app dùng `--desktop-api 1` và nhận envelope version/ok/result hoặc error(code/message/remediation). Từ chối version không hỗ trợ trước dispatch. Mọi phản hồi app đều được Swift kiểm tra version và exit status. Lỗi không biết không xuất raw exception. Capability được kiểm tra khi khởi động. Sức khỏe clone đọc nhẹ khi refresh, kiểm tra chữ ký khi doctor. UI dùng một trạng thái thao tác để cập nhật cửa sổ/menu, chỉ cho hủy giai đoạn chờ; phân biệt sync hoàn tất và mở lại thất bại.

- [x] Viết/chạy test đỏ cho envelope, version không hợp lệ không dispatch, lỗi không lộ dữ liệu, CLI tương thích và tình trạng profile.
- [x] Thêm backend_protocol.py, tích hợp CLI manager và runtime manifest; giữ khóa backend là nguồn quyết định ghi.
- [x] Viết/chạy Swift contract tests; kiểm tra envelope và runtime được cài trong thư mục tạm qua dispatcher thật.
- [x] Tích hợp capability, trạng thái UI/menu, health và hành động repair/recover có phạm vi rõ; không gọi tự động.
- [x] Thêm release verifier + CI macOS (worker phụ trách build.py, verify_release.py, test_release.py, workflow).
- [x] Chạy Python suite, Swift tests, build/verifier; review độc lập và sửa phát hiện trước bàn giao.

Validation không dùng tài khoản thật. Build chỉ tạo artifact trong dist; không cài, mở Claude, phát hành hay ghi profile thật.

Kết quả: 121 test Python qua; Swift test process/protocol, dispatcher/runtime tạm, trạng thái UI/menu, ba profile có lỗi chữ ký và luồng sync/xác minh qua. Build arm64 và kiểm tra app/ZIP/chữ ký/entitlement qua. Đã xem ảnh giao diện render từ fixture; không chạy sync hoặc sửa profile thật. Review độc lập phát hiện và đã sửa bốn lỗi về kết quả doctor, refresh sau lỗi, validation tạo profile và điều kiện bật Sync. CI mới được thêm; chưa có kết quả chạy GitHub Actions cho thay đổi chưa push.
