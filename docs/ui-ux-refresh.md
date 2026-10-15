# Cải tiến UI/UX native của Claude Harbor

Mục tiêu: giúp người dùng biết tài khoản nào dùng được, tài khoản nào đang được chọn chia sẻ lịch sử, và cần làm gì trước khi đồng bộ. Giữ AppKit/Python và phạm vi chia sẻ dữ liệu hiện có.

Thiết kế triển khai: cửa sổ resizable có Auto Layout; thanh đầu nhận diện Harbor và tác vụ thêm/làm mới/kiểm tra; danh sách tài khoản có biểu tượng, tên, trạng thái bằng chữ, checkbox Đồng bộ và thao tác mở/sửa. Vùng cuối riêng cho tiến trình/kết quả và điều kiện đồng bộ. Empty state hướng dẫn bắt đầu; thông báo phục hồi có nút Kiểm tra. Các trường thêm tài khoản có nhãn và validation tại chỗ. Dùng system font, SF Symbols và màu semantic để theo light/dark của macOS. Không thêm animation trang trí hay bulk-select tự chia sẻ lịch sử.

1. Test điều kiện bật Sync/lý do chặn, empty/pending/recovery và trạng thái bị khóa khi bận.
2. Thay layout frame cố định bằng Auto Layout; thêm hierarchy, empty state, selection summary và health banner.
3. Cải tiến form thêm tài khoản: nhãn, giải thích, lỗi tên tại chỗ, giữ nội dung khi backend thất bại.
4. Render fixture light/dark, cửa sổ nhỏ/lớn, tên dài/nhiều tài khoản và trạng thái bận; kiểm tra bố cục và accessibility labels.
5. Chạy Swift tests, Python regression suite, build/verifier và review độc lập.

Không cài/khởi chạy Claude thật hoặc ghi tài khoản thật trong kiểm thử. Các ảnh preview dùng fixture.

Kết quả: đã hoàn tất giao diện co giãn, badge trạng thái, đếm lựa chọn, lý do chặn Sync, trạng thái trống, cảnh báo phục hồi, cửa sổ chi tiết hoạt động có thể chọn/sao chép nội dung và form thêm tài khoản có retry. Phím tắt và menu Edit phục vụ bàn phím; checkbox/nút từng tài khoản có accessibility label. Auto Layout giữ vị trí cuộn và focus khi refresh. Không có animation trang trí.

Validation: 121 test Python qua; hai chương trình test Swift (backend/protocol/UI và form thêm tài khoản) qua. Đã render và xem các fixture sáng/tối, rỗng, 15 tài khoản/tên dài ở 820×720, phục hồi, đang sync và form. Test hồi quy xác nhận health từ doctor thay thế dữ liệu cũ và form giãn theo lỗi dài. Review độc lập không còn phát hiện P1/P2 sau sửa. Build arm64, chữ ký, entitlement và app/ZIP verifier qua. Chưa thao tác tài khoản thật, cài đè hoặc phát hành. GitHub CI mới được cấu hình nhưng chưa chạy trên remote cho thay đổi chưa push.
