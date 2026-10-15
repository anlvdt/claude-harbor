# Claude Harbor

**Nhiều tài khoản Claude. Một nơi để mở app và đồng bộ phiên Code local.**

Claude Harbor là app macOS nhỏ giúp tạo nhiều bản Claude Desktop thật, đăng nhập riêng từng tài khoản và tiếp tục lịch sử Code giữa các profile được chọn rõ ràng bằng một nút.

[Bản đã phát hành: v0.2.0](https://github.com/anlvdt/claude-harbor/releases/tag/v0.2.0) · [English](README.md)

![Giao diện Claude Harbor](docs/screenshots/claude-harbor-native.png)

## Cách dùng

1. Cài Claude Desktop chính thức tại `/Applications/Claude.app`. Cần macOS 14+, Apple Silicon và Apple Command Line Tools (`xcode-select --install`).
2. Tải ZIP từ Releases, giải nén rồi đặt **Claude Harbor.app** trong Applications.
3. Bấm **+ Thêm tài khoản**, đặt tên rồi đăng nhập trong bản Claude mới.
4. Mở tab **Code**, tạo một phiên **Local**, quay lại Harbor bấm **Làm mới**.
5. Khi có ít nhất hai profile sẵn sàng, chọn ô **Sync** ở các profile được phép chia sẻ lịch sử, rồi bấm **Đồng bộ đã chọn**. App chờ trả lời xong, đóng các app đang chạy, sao lưu và đồng bộ, rồi chỉ mở lại các app đã chạy trước đó.

**Mở / Mở tất cả** để chạy các tài khoản đồng thời. Menu **C≋** trên thanh menu giúp mở nhanh và đồng bộ. **Báo cáo & hoạt động** xem kết quả gần đây và mở thư mục báo cáo/bản sao lưu.

Bản ứng viên 0.3.0 (build 3) đã được chuẩn bị trong mã nguồn, chưa phát hành; ZIP công khai vẫn là v0.2.0. [Hướng dẫn release 0.3.0](docs/release-0.3.0.md) ghi rõ checksum, lựa chọn ký và phần chưa kiểm thử. Các thay đổi: tình trạng clone hiển thị ngay tại profile; nút **Sửa** tạo lại app khi đã đóng các profile; **Kiểm tra → Phục hồi** xử lý giao dịch dở dang. Cửa sổ và menu bar cùng báo tiến trình, chỉ cho dừng lúc chờ trả lời. Sau khi đồng bộ, Harbor xác minh lịch sử trước khi mở lại các app; lỗi xác minh và lỗi mở lại được báo riêng. Xem [hướng dẫn build](README.md#build-from-source) để dùng bản mới.

Giao diện mới co giãn theo cửa sổ và theo chế độ sáng/tối của macOS. Mỗi tài khoản có nhãn trạng thái, lựa chọn **Đồng bộ** và thao tác mở/sửa riêng; vùng đồng bộ giải thích rõ điều kiện còn thiếu. Form thêm tài khoản báo lỗi ngay tại trường tên và giữ nội dung nếu tạo thất bại. Phím tắt: **⌘N** thêm, **⌘O** mở tất cả, **⌘R** làm mới, **⌘I** kiểm tra và **⌘Return** đồng bộ.

Bản công khai v0.2.0 và build mặc định ký ad-hoc, chưa được Apple notarize; macOS có thể yêu cầu bạn cho phép mở app tải về. Giao diện hiện bằng tiếng Việt. Build 0.3.0 hỗ trợ tùy chọn Developer ID + hardened runtime và notarization bằng identity/profile Keychain có sẵn; máy chuẩn bị release không có identity hợp lệ hay metadata profile notarytool nên chưa kiểm thử luồng Apple thực tế.

**Nhập lịch sử…** chọn thư mục cấu hình Code chứa `projects`, tùy chọn metadata Desktop và xác nhận các tài khoản nhận. **Xác minh lịch sử** kiểm tra riêng tính nhất quán. Hai thao tác cần ít nhất một profile đã chọn và sẵn sàng, đóng các clone và xử lý lỗi chặn/phục hồi trước. Nhật ký hoạt động chỉ lưu thời gian, loại thao tác, kết quả và số lượng; báo cáo chi tiết có thể chứa thông tin riêng tư.

Smoke `python3 scripts/smoke_real_claude.py` chỉ chạy headless: tạo/ký/kiểm tra clone thật và sync/xác minh/sửa với lịch sử fixture, không mở Electron. Thử GUI với HOME tạm trước đó gây hộp thoại Keychain; đã xử lý bằng cách dừng tiến trình thử. Chưa xác nhận mở GUI, đăng nhập hay mở lại sau repair.

## Đã hỗ trợ

- Mỗi bản Claude có dữ liệu đăng nhập riêng.
- Đồng bộ transcript và đăng ký phiên giữa các profile đã chọn để hiện trong sidebar Code.
- Nhập lịch sử local cũ/đã lưu trữ theo nguồn và đích được chỉ định rõ ràng.
- Giữ nhiều nhánh nếu hội thoại được tiếp tục khác nhau giữa các tài khoản.
- Journal bền vững, sao lưu và phục hồi giao dịch dở dang trước khi ghi tiếp.
- **Kiểm tra** clone/profile và repair có chủ đích sau khi Claude Desktop đổi phiên bản.
- Profile chưa đăng nhập / chưa mở Code được báo chờ; các profile khác vẫn đồng bộ.

Đã đối chiếu thực tế **3.146 nhóm phiên ở ba profile**, không thiếu bản sao và không khác nội dung hội thoại trong phạm vi đã đồng bộ.

## Giới hạn

Chỉ đồng bộ **Code local trên cùng máy** của các profile đã chọn. Chưa hỗ trợ Chat web, Cowork, cloud hoặc nhiều máy; không tự khôi phục transcript đã xóa hay trên ổ chưa kết nối. Cần đóng các bản Claude trong lúc ghi đồng bộ. Sau khi Claude Desktop đổi phiên bản, dùng **Kiểm tra** rồi repair từng clone đã đóng nếu cần.

Preset Magpie là cấu hình gateway local đã kiểm chứng, chưa phải trình cấu hình API/model bất kỳ. Model cụ thể phụ thuộc routing của Magpie.

[Chi tiết cài đặt, build và dữ liệu](README.md) · [Cách đồng bộ](docs/session-sync.md).

Mã nguồn MIT. Đây là công cụ cộng đồng độc lập, không phải sản phẩm chính thức của Anthropic.
