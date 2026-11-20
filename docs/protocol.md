# Protocol (TCP là byte stream => cần framing)

Mọi message (request và response) có cùng định dạng, big-endian:

| Offset | Kích thước | Nội dung |
|---|---|---|
| 0 | 4 byte | `N` = độ dài body = 8 + độ dài payload |
| 4 | 8 byte | `requestId` (client: `(clientId << 32) | seq`) |
| 12 | N-8 byte | `payload` (thí nghiệm: 1024 byte => N = 1032, frame = 1036 byte) |

- Server đọc 4 byte `N`, kiểm tra `8 <= N <= 65536`, rồi `readFully` đúng N byte, echo nguyên frame.
- `N` không hợp lệ / vượt giới hạn => server đóng connection đó (server vẫn chạy).
- Không có dữ liệu trong `read timeout` (mặc định 30 s) => server đóng connection.
- Client kiểm tra response: `requestId` và payload phải khớp request.
