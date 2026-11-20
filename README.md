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
- **Quy chuẩn đo lường:**
  - Kích thước payload cố định: `1024 bytes` (1 KB).
  - Thời gian Warm-up: `5 giây` (bỏ qua số liệu giai đoạn này để JIT và JVM ổn định).
  - Thời gian đo chính thức: `20 giây`.
  - Số lượt lặp lại: Ít nhất `3 lần` cho mỗi kịch bản (1, 10, 50 Clients) để tính giá trị trung bình (Mean) và độ lệch chuẩn (StdDev).

---

## 2. Cấu Trúc Repository

Cấu trúc dự án tuân thủ nghiêm ngặt theo đặc tả Mục 5 của đề bài:

```text
project-root/
├── README.md
├── pom.xml
├── .gitignore
├── src/
│   ├── server/                                # Thư mục định danh theo đề bài
│   ├── load-generator/                        # Ứng dụng tạo tải độc lập (TV2)
│   │   ├── LoadGeneratorApp.java
│   │   ├── BenchmarkWorker.java
│   │   └── MetricsCollector.java
│   └── main/java/com/research/
│       ├── common/
│       │   └── Protocol.java                  # Hằng số giao thức chung (TV1 & TV2)
│       └── server/                            # Mã nguồn TCP Server đa luồng (TV1)
│           ├── TCPEchoServer.java
│           ├── ClientHandler.java
│           └── CpuMonitor.java
├── experiments/
│   ├── configs/
│   │   └── benchmark_config.json
│   ├── scripts/
│   │   ├── run_benchmarks.ps1
│   │   └── run_validation_tests.ps1
│   ├── raw-data/
│   ├── analysis/
│   │   └── analyze_data.py
│   └── figures/
│       ├── throughput_vs_clients.png
│       ├── latency_vs_clients.png
│       └── cpu_vs_clients.png
└── docs/
    ├── protocol.md                            # Đặc tả kỹ thuật giao thức Framing (TV1)
    ├── SUBMISSION_CHECKLIST.md                # Checklist kiểm soát hồ sơ nộp bài (TV6)
    └── REPORT.pdf                             # Báo cáo học thuật 4–6 trang (TV5 & TV6)
```

---

## 3. Yêu Cầu Môi Trường (Prerequisites)

Để biên dịch và chạy trọn vẹn dự án, máy tính cần cài đặt:

1. **Java Development Kit (JDK):** JDK 17+ (khuyến nghị **JDK 21 LTS**). Kiểm tra bằng:
   ```bash
   java -version
   javac -version
   ```
2. **PowerShell:** PowerShell 5.1 (sẵn có trên Windows) hoặc PowerShell 7+.
3. **Python 3:** Phiên bản 3.8+ phục vụ phân tích số liệu và vẽ biểu đồ:
   ```bash
   python --version
   pip install pandas numpy matplotlib seaborn
   ```
4. **Apache Maven (tùy chọn):** Hỗ trợ quản lý vòng đời dự án:
   ```bash
   mvn -version
   ```

---

## 4. Tái Tạo Thực Nghiệm Nhanh (1–2 Câu Lệnh)

Nhóm đã cung cấp kịch bản tự động hóa hoàn toàn quy trình biên dịch, chạy tải, thu thập số liệu và vẽ đồ thị.

### Bước 1: Chạy tự động ma trận đo lường & kiểm thử chịu lỗi

Mở terminal PowerShell tại thư mục gốc của dự án và chạy:

```powershell
powershell -ExecutionPolicy Bypass -File .\experiments\scripts\run_benchmarks.ps1
```

_Script sẽ tự động:_

- Biên dịch mã nguồn Java.
- Khởi động `TCPEchoServer` trên cổng `8080`.
- Chạy ma trận 3 mức tải $\times$ 3 lần lặp (1, 10, 50 Clients; mỗi lần 5s warm-up + 20s đo chính thức).
- Ghi dữ liệu thô vào `experiments/raw-data/benchmark_results.csv` và `cpu_metrics.csv`.
- Tự động chạy tiếp 4 ca kiểm thử chịu lỗi (TC1 đến TC4).

> **Mẹo tái lập nhanh (Quick Test):** Để chạy nhanh 1 kịch bản kiểm tra (ví dụ 10 clients, 1 lần lặp, đo 5 giây):
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\experiments\scripts\run_benchmarks.ps1 -Clients 10 -Runs 1 -DurationSec 5 -WarmupSec 2
> ```

### Bước 2: Phân tích số liệu và tự động sinh biểu đồ

Chạy script phân tích dữ liệu:

```bash
python experiments/analysis/analyze_data.py
```

_Script sẽ tính toán Mean, StdDev và tự động xuất ra thư mục `experiments/figures/`:_

1. `throughput_vs_clients.png` (Thông lượng theo số Client)
2. `latency_vs_clients.png` (Độ trễ trung bình & đuôi trễ p95)
3. `cpu_vs_clients.png` (Mức tiêu thụ CPU của Server)
4. Bảng tổng hợp số liệu kiểm chứng: `experiments/analysis/summary_metrics.csv`

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
java -cp bin com.research.server.TCPEchoServer --port 8080
```

_Server sẽ mở Socket lắng nghe tại cổng `8080` (mô hình Blocking Socket + Thread Pool) và khởi chạy luồng nền giám sát CPU._

### 5.3. Khởi động Load Generator (Process 2)

Mở một cửa sổ dòng lệnh thứ hai để bắn tải:

```bash
java -cp bin LoadGeneratorApp --host 127.0.0.1 --port 8080 --clients 10 --warmup 5 --duration 20 --payload 1024 --csv experiments/raw-data/manual_run.csv
```

**Các tham số dòng lệnh của Load Generator:**
| Tham số | Giá trị mặc định | Giải thích ý nghĩa |
| :--- | :---: | :--- |
| `--host` | `127.0.0.1` | Địa chỉ IP của máy chủ TCP |
| `--port` | `8080` | Cổng dịch vụ lắng nghe |
| `--clients` | `1` | Số lượng luồng Client đồng thời (mỗi client 1 socket riêng) |
| `--warmup` | `5` | Thời gian chạy khởi động làm nóng (giây), không ghi số liệu |
| `--duration`| `20` | Thời gian đo lường chính thức (giây) |
| `--payload` | `1024` | Kích thước mảng byte dữ liệu mỗi request |
| `--csv` | `benchmark_results.csv` | Đường dẫn file lưu kết quả chi tiết từng đợt chạy |

---

## 6. Bộ Kiểm Thử Chức Năng & Chịu Lỗi (Validation Tests)

Dự án tích hợp sẵn bộ kiểm chứng tự động cho 4 ca thử nghiệm bắt buộc (theo Mục 4 Đề bài):

```powershell
powershell -ExecutionPolicy Bypass -File .\experiments\scripts\run_validation_tests.ps1
```

- **TC1 (Tải đơn vs Tải cao):** Đo lường tính ổn định và so sánh trực tiếp hiệu năng giữa 1 Client và 50 Clients đồng thời.
- **TC2 (Kiểm chứng tính toàn vẹn dữ liệu):** Đối chiếu chính xác từng byte của `requestId` và `payload` phản hồi so với request gửi đi qua các dải kích thước (0B, 16B, 1KB, 32KB, 64KB) và khi xảy ra phân mảnh luồng TCP.
- **TC3 (Chịu lỗi ngắt kết nối đột ngột):** Khi tải đang chạy tối đa (50 clients), cưỡng bức tắt tiến trình Client (`kill /F` hoặc ngắt nửa frame TCP RST). Kiểm tra xác nhận Server vẫn tiếp tục sống và phản hồi bình thường cho các kết nối mới.
- **TC4 (Xử lý dữ liệu sai / vượt ngưỡng):** Gửi gói tin có `length > 64KB` (vượt `MAX_BODY`) hoặc frame bị rác/cắt cụt phần header. Xác nhận Server đóng kết nối vi phạm an toàn mà không bị crash hoặc treo bộ nhớ.

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
- **Request ID (8 bytes):** Mã định danh tuần tự của request để đối chiếu tính toàn vẹn.
- **Payload (1024 bytes):** Mảng byte dữ liệu nhị phân.
- **Tổng kích thước 1 Frame chuẩn:** $4 + 8 + 1024 = 1036 \text{ bytes}$.
- **Quy tắc giải mã:** Phía nhận luôn đọc chính xác 4 byte header trước bằng `readFully()`. Nếu $N > 65536$ bytes (`MAX_BODY`), kết nối bị ngắt ngay lập tức để bảo vệ Server.

---

## 8. Công Thức & Chỉ Số Hiệu Năng

Dữ liệu RTT (Round Trip Time) được bấm giờ bằng đồng hồ độ phân giải nano-giây: `System.nanoTime()`.

- **Throughput (req/s):**
  $$\text{Throughput} = \frac{\text{Tổng số request phản hồi thành công}}{\text{Thời gian đo chính thức (20 giây)}}$$
- **Average Latency (ms):**
  $$\text{Avg Latency} = \frac{1}{K} \sum_{i=1}^{K} \text{RTT}_i$$
- **p95 Tail Latency (ms):**
  Sắp xếp danh sách RTT tăng dần, giá trị p95 là phần tử tại vị trí: $\lceil 0.95 \times K \rceil - 1$.
- **Error Rate (%):**
  $$\text{Error Rate} = \frac{\text{Số request lỗi hoặc timeout}}{\text{Tổng số request phát đi}} \times 100$$
- **CPU Usage (%):**
  Lấy từ `OperatingSystemMXBean.getProcessCpuLoad() * 100` ghi nhận định kỳ mỗi giây một lần.

---
