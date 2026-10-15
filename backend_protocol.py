"""Versioned desktop boundary. Unknown failures never expose exception contents."""
import json

VERSION = 1
FEATURES = ('structured_errors', 'profile_health', 'recovery_status')
MESSAGES = {
    'protocol_incompatible': ('Giao diện và runtime không tương thích.', 'Mở lại Harbor từ cùng một bản cài đặt để cập nhật runtime.'),
    'invalid_request': ('Lệnh hoặc tham số không hợp lệ.', 'Làm mới Harbor rồi thử lại thao tác.'),
    'invalid_profile_name': ('Tên profile không hợp lệ.', 'Dùng tên từ 1 đến 60 ký tự, không chứa /, \\, :, ký tự NUL hoặc xuống dòng.'),
    'duplicate_profile': ('Tên profile hoặc app này đã được sử dụng.', 'Chọn một tên khác cho bản Claude mới.'),
    'source_unavailable': ('Chưa tìm thấy Claude Desktop gốc.', 'Cài Claude Desktop tại /Applications/Claude.app rồi thử lại.'),
    'store_busy': ('Dữ liệu đang được app hoặc thao tác khác sử dụng.', 'Chờ thao tác hiện tại hoàn tất; đóng các profile trước khi sửa hoặc phục hồi.'),
    'profiles_running': ('Một hoặc nhiều profile vẫn đang chạy.', 'Đóng các profile rồi thử lại.'),
    'import_source_busy': ('Nguồn nhập đang được sử dụng.', 'Đóng Claude và công cụ đang ghi nguồn hoặc dùng bản sao lưu đã đóng, rồi thử lại.'),
    'import_source_unchecked': ('Chưa kiểm tra được nguồn nhập có đang được ghi hay không.', 'Kiểm tra quyền đọc nguồn và công cụ lsof; dùng bản sao lưu đã đóng rồi thử lại.'),
    'profile_missing': ('Không tìm thấy profile đã chọn.', 'Làm mới danh sách và chọn lại profile.'),
    'profiles_not_ready': ('Chưa đủ profile sẵn sàng cho thao tác.', 'Đăng nhập, mở tab Code, tạo phiên local và chọn ít nhất hai profile để đồng bộ.'),
    'clone_stale': ('Bản Claude cần được sửa trước khi đồng bộ.', 'Đóng các profile, chọn Kiểm tra rồi sửa bản Claude bị lỗi.'),
    'recovery_required': ('Có giao dịch chưa hoàn tất hoặc nhật ký không đọc được.', 'Đóng các profile rồi dùng Phục hồi trong Kiểm tra. Giữ lại bản sao lưu nếu phục hồi bị chặn.'),
    'verification_failed': ('Kiểm tra phát hiện lịch sử chưa đồng nhất.', 'Mở Báo cáo & sao lưu, xem last-verification.json trước khi đồng bộ lại.'),
    'permission_denied': ('Không có quyền truy cập dữ liệu cần thiết.', 'Kiểm tra quyền truy cập thư mục dữ liệu và các bản Claude.'),
    'operation_failed': ('Không hoàn tất được thao tác.', 'Chạy Kiểm tra để xem tình trạng profile và phục hồi; giữ lại các bản sao lưu.'),
}


class BackendError(Exception):
    def __init__(self, code, legacy_result=None):
        self.code = code
        self.legacy_result = legacy_result
        super().__init__(MESSAGES[code][0])


def failure(error):
    if isinstance(error, BackendError): code = error.code
    elif isinstance(error, BlockingIOError): code = 'store_busy'
    elif isinstance(error, PermissionError): code = 'permission_denied'
    else: code = 'operation_failed'
    message, remediation = MESSAGES[code]
    return {'code': code, 'message': message, 'remediation': remediation}


def envelope(result=None, error=None):
    if error is not None:
        return {'protocolVersion': VERSION, 'ok': False, 'error': failure(error)}
    return {'protocolVersion': VERSION, 'ok': True, 'result': result}


def encode(payload):
    return json.dumps(payload, ensure_ascii=False, allow_nan=False)
