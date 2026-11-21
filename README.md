# Khảo Sát Ảnh Hưởng Của Số Lượng Client Đồng Thời Đến Hiệu Năng TCP Server

Dự án nghiên cứu thực nghiệm đo lường và đánh giá hiệu năng của **TCP Server** (mô hình Blocking Socket đa luồng với Thread Pool) khi quy mô Client đồng thời thay đổi, tập trung vào 4 chỉ số cốt lõi: **Throughput (req/s)**, **Average Latency (ms)**, **Tail Latency p95 (ms)** và **CPU Usage (%)**.

---

## 1. Câu Hỏi Nghiên Cứu & Phạm Vi

### Câu hỏi nghiên cứu:

> _Khi số lượng Client đồng thời tăng (tối thiểu 1, 10, 50 Clients), độ trễ (latency), thông lượng (throughput) và mức sử dụng CPU của TCP Server thay đổi như thế nào?_

### Phạm vi và Ràng buộc kỹ thuật:

- **Mô hình dịch vụ:** Request/Response tối giản theo dạng **Echo Benchmark**.
- **Kiến trúc mạng:** TCP Server và Load Generator chạy ở hai tiến trình (process) độc lập; mỗi Client logic duy trì một kết nối TCP riêng biệt.
- **Cơ chế Framing:** Giao thức phân tách message rõ ràng (Length-prefixing) để giải quyết triệt để tính chất dòng byte (stream-oriented) của TCP (chống dính gói và xé gói).
- **Giá trị mặc định của Load Generator:** Payload `1024 bytes`, warm-up `5 giây`, thời gian đo `20 giây`. Đây là mặc định chương trình, không phải bằng chứng rằng các lần chạy benchmark đã được thực hiện.
- **Kịch bản nghiên cứu dự kiến:** 1, 10, 50 clients; repository hiện chưa có dữ liệu chạy lặp để tính Mean/StdDev.

---

## 2. Cấu Trúc Repository Hiện Có

Cấu trúc dự án:

````text
project-root/
├── README.md
├── pom.xml
├── .gitignore
├── src/
│   ├── server/
│   ├── load-generator/
│   │   ├── LoadGeneratorApp.java
│   │   ├── BenchmarkWorker.java
│   │   └── MetricsCollector.java
│   └── main/java/com/research/
│       ├── common/
│       │   └── Protocol.java
│       └── server/
│           ├── TCPEchoServer.java
│           ├── ClientHandler.java
│           └── CpuMonitor.java
├── experiments/
│   ├── configs/
│   ├── raw-data/
│   └── figures/
└── docs/
    ├── protocol.md


---

## 3. Yêu Cầu Môi Trường (Prerequisites)

Để biên dịch và chạy trọn vẹn dự án, máy tính cần cài đặt:

1. **Java Development Kit (JDK):** `pom.xml` khai báo compiler source/target 26; dùng JDK tương thích mức này để biên dịch. Phiên bản JVM thực tế cần được ghi nhận riêng khi chạy benchmark. Kiểm tra bằng:
   ```bash
   java -version
   javac -version
````

2. **PowerShell:** PowerShell 5.1 (sẵn có trên Windows) hoặc PowerShell 7+.
3. **Python 3:** Cần nếu muốn chạy script tạo PDF. Repository hiện chưa có script phân tích benchmark hoặc vẽ biểu đồ:
   ```bash
   python --version
   pip install pandas numpy matplotlib seaborn
   ```
4. **Apache Maven (tùy chọn):** Hỗ trợ quản lý vòng đời dự án:
   ```bash
   mvn -version
   ```

---

## 4. Trạng Thái Tái Tạo Thực Nghiệm

Repository hiện chưa có script tự động chạy ma trận benchmark, validation, phân tích dữ liệu hoặc vẽ biểu đồ. Các thư mục tương ứng hiện chỉ là placeholder; chưa có dữ liệu thực nghiệm được lưu.

Có thể chạy thủ công một kịch bản theo Mục 5 bên dưới. Việc này không tự động lặp ma trận 1/10/50 clients, tổng hợp thống kê hoặc sinh biểu đồ.

---

## 5. Hướng Dẫn Vận Hành Thủ Công

Nếu muốn tự kiểm soát từng tiến trình độc lập bằng tay:

### 5.1. Biên dịch mã nguồn Java

```bash
# Biên dịch toàn bộ các module vào thư mục bin/
javac -encoding UTF-8 -d bin src/main/java/com/research/common/*.java src/main/java/com/research/server/*.java src/load-generator/*.java
```

Hoặc biên dịch thông qua Maven:

```bash
mvn clean compile
```

### 5.2. Khởi động TCP Server (Process 1)

```bash
java -cp bin com.research.server.TCPEchoServer --port 8080 --cpu-log experiments/raw-data/cpu_server.csv
```

_Server sẽ mở Socket lắng nghe tại cổng `8080` (mô hình Blocking Socket + Thread Pool 256 workers) và khởi chạy luồng nền `CpuMonitor` ghi nhận tải CPU mỗi giây ra file CSV._

**Các tham số dòng lệnh của TCP Server:**
| Tham số | Giá trị mặc định | Giải thích ý nghĩa |
| :--- | :---: | :--- |
| `--host` | `0.0.0.0` | Địa chỉ IP giao diện mạng lắng nghe (0.0.0.0 cho tất cả card mạng) |
| `--port` | `9000` | Cổng dịch vụ (khuyến nghị truyền `--port 8080` để đồng bộ với LoadGen) |
| `--pool` | `256` | Số lượng luồng worker tối đa trong `FixedThreadPool` |
| `--timeout-ms` | `30000` | Thời gian chờ đọc dữ liệu tối đa (`SO_TIMEOUT`) trước khi đóng socket |
| `--cpu-log` | `null` | Đường dẫn file CSV xuất dữ liệu CPU tiến trình và toàn hệ thống |
| `--cpu-interval-ms` | `1000` | Chu kỳ lấy mẫu CPU (mili-giây) |
| `--verbose` | `false` | Bật chế độ in chi tiết log kết nối/ngắt kết nối ra màn hình |

### 5.3. Khởi động Load Generator (Process 2)

Mở một cửa sổ dòng lệnh thứ hai để bắn tải:

```bash
java -cp bin LoadGeneratorApp --host 127.0.0.1 --port 8080 --clients 10 --warmup 5 --duration 20 --payload 1024 --csv experiments/raw-data/manual_run.csv --json experiments/raw-data/run_latest.json
```

**Các tham số dòng lệnh của Load Generator:**
| Tham số | Giá trị mặc định | Giải thích ý nghĩa |
| :--- | :---: | :--- |
| `--host` | `127.0.0.1` | Địa chỉ IP của máy chủ TCP |
| `--port` | `8080` | Cổng dịch vụ lắng nghe |
| `--clients` | `1` | Số lượng luồng Client đồng thời (mỗi client 1 socket riêng biệt) |
| `--warmup` | `5` | Thời gian chạy khởi động làm nóng (giây), không ghi số liệu |
| `--duration`| `20` | Thời gian đo lường chính thức (giây) |
| `--payload` | `1024` | Kích thước mảng byte dữ liệu mỗi request (mặc định 1 KB) |
| `--run-id` | `1` | Mã định danh của đợt chạy thực nghiệm |
| `--csv` | `benchmark_results.csv` | Đường dẫn file lưu kết quả chi tiết từng đợt chạy |
| `--json` | `run_latest.json` | Đường dẫn file JSON xuất kết quả tóm tắt đợt chạy mới nhất |
| `--test-invalid` | `false` | Gửi frame độ dài dị tật (999,999,999 bytes) kiểm thử phản ứng Server |
| `--kill-early` | `false` | Cưỡng bức đóng socket sau 5 request để kiểm thử chịu lỗi Server |

---

## 6. Bộ Kiểm Thử Chức Năng & Chịu Lỗi (Validation Tests)

Repository chưa có bộ kiểm thử tự động TC1–TC4. Load Generator có tùy chọn `--test-invalid` để gửi length `999999999` và `--kill-early` để worker đóng socket sau 5 request; tùy chọn thứ hai không kill tiến trình Load Generator hoặc chủ động tạo TCP RST. Benchmark bình thường so sánh `requestId` và payload đã cấu hình; chưa có test matrix các kích thước biên hoặc ép phân mảnh. Với `MAX_BODY = 65536` bao gồm 8 byte request ID, payload tối đa hợp lệ là 65528 bytes (payload 65536 bytes bị từ chối).

---

## 7. Đặc Tả Giao Thức (Protocol Specification)

Để xử lý bài toán **TCP Streaming** (dữ liệu không có ranh giới gói tin, có thể bị dính hoặc cắt nhỏ qua bộ đệm hệ điều hành), hệ thống sử dụng định dạng nhị phân theo chuẩn **Length-Prefix**:

### Cấu trúc Byte Frame:

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Body Length (N)                         |  4 bytes (int, Big-Endian)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                        Request ID (long)                      |  8 bytes (long, Big-Endian)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                     Payload Data (N - 8 bytes)               |  1024 bytes (mặc định)
|                             ...                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **Header (4 bytes):** Độ dài $N$ của phần thân body (bằng $8 + \text{Payload length}$).
- **Request ID (8 bytes):** Giá trị tăng dần dùng chung từ `AtomicLong`, dùng đối chiếu response với request.
- **Payload (1024 bytes):** Mảng byte dữ liệu nhị phân.
- **Tổng kích thước 1 Frame chuẩn:** $4 + 8 + 1024 = 1036 \text{ bytes}$.
- **Quy tắc giải mã:** Server đọc header bằng cách ghép 4 byte (byte đầu dùng `read()`, ba byte còn lại dùng `readUnsignedByte()`), kiểm tra $8 \le N \le 65536$, rồi dùng `readFully()` đọc body. Payload tối đa hợp lệ là 65528 bytes do 8 bytes body dùng cho request ID.

---

## 8. Công Thức & Chỉ Số Hiệu Năng

Dữ liệu RTT (Round Trip Time) được bấm giờ bằng đồng hồ độ phân giải nano-giây: `System.nanoTime()`.

- **Throughput (req/s):**
  $$\text{Throughput} = \frac{\text{Số request thành công được ghi nhận}}{\text{durationSec}}$$
- **Average Latency (ms):**
  $$\text{Avg Latency} = \frac{1}{K} \sum_{i=1}^{K} \text{RTT}_i$$
- **p95 Tail Latency (ms):**
  Sắp xếp danh sách RTT tăng dần, giá trị p95 là phần tử tại vị trí: $\lceil 0.95 \times K \rceil - 1$.
- **Error Rate (%):**
  $$\text{Error Rate} = \frac{\text{totalErrors}}{\text{totalSuccess} + \text{totalErrors}} \times 100$$
- **CPU Usage (%):**
  `CpuMonitor` tính phần trăm một lõi từ chênh lệch `getProcessCpuTime()` theo thời gian thực; đồng thời ghi mức chuẩn hóa theo số lõi và `getCpuLoad()` cho toàn hệ thống. Chu kỳ mặc định là 1 giây.

---
