# Khảo Sát Ảnh Hưởng Của Số Lượng Client Đồng Thời Đến Hiệu Năng TCP Server

[![Java](https://img.shields.io/badge/Java-21%2B%20LTS-orange.svg)](https://www.oracle.com/java/)
[![Protocol](https://img.shields.io/badge/Protocol-TCP%20Binary%20Framing-blue.svg)](#giao-thức-truyền-thông-protocol-specification)
[![Python](https://img.shields.io/badge/Python-3.8%2B-brightgreen.svg)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-Academic%20Research-lightgrey.svg)](#)

Dự án nghiên cứu thực nghiệm đo lường và đánh giá hiệu năng của **TCP Server** (mô hình Blocking Socket đa luồng với Thread Pool) khi quy mô Client đồng thời thay đổi, tập trung vào 4 chỉ số cốt lõi: **Throughput (req/s)**, **Average Latency (ms)**, **Tail Latency p95 (ms)** và **CPU Usage (%)**.

---

## Mục Lục
- [1. Câu Hỏi Nghiên Cứu & Phạm Vi](#1-câu-hỏi-nghiên-cứu--phạm-vi)
- [2. Cấu Trúc Repository](#2-cấu-trúc-repository)
- [3. Yêu Cầu Môi Trường (Prerequisites)](#3-yêu-cầu-môi-trường-prerequisites)
- [4. Tái Tạo Thực Nghiệm Nhanh (1–2 Câu Lệnh)](#4-tái-tạo-thực-nghiệm-nhanh-12-câu-lệnh)
- [5. Hướng Dẫn Vận Hành Thủ Công](#5-hướng-dẫn-vận-hành-thủ-công)
- [6. Bộ Kiểm Thử Chức Năng & Chịu Lỗi (Validation Tests)](#6-bộ-kiểm-thử-chức-năng--chịu-lỗi-validation-tests)
- [7. Đặc Tả Giao Thức (Protocol Specification)](#7-đặc-tả-giao-thức-protocol-specification)
- [8. Công Thức & Chỉ Số Hiệu Năng](#8-công-thức--chỉ-số-hiệu-năng)
- [9. Đóng Gói Hồ Sơ Nộp Bài (Packaging)](#9-đóng-gói-hồ-sơ-nộp-bài-packaging)
- [10. Phân Công Trách Nhiệm Nhóm](#10-phân-công-trách-nhiệm-nhóm)

---

## 1. Câu Hỏi Nghiên Cứu & Phạm Vi

### Câu hỏi nghiên cứu:
> *Khi số lượng Client đồng thời tăng (tối thiểu 1, 10, 50 Clients), độ trễ (latency), thông lượng (throughput) và mức sử dụng CPU của TCP Server thay đổi như thế nào?*

### Phạm vi và Ràng buộc kỹ thuật:
* **Mô hình dịch vụ:** Request/Response tối giản theo dạng **Echo Benchmark**.
* **Kiến trúc mạng:** TCP Server và Load Generator chạy ở hai tiến trình (process) độc lập; mỗi Client logic duy trì một kết nối TCP riêng biệt.
* **Cơ chế Framing:** Giao thức phân tách message rõ ràng (Length-prefixing) để giải quyết triệt để tính chất dòng byte (stream-oriented) của TCP (chống dính gói và xé gói).
* **Quy chuẩn đo lường:**
  * Kích thước payload cố định: `1024 bytes` (1 KB).
  * Thời gian Warm-up: `5 giây` (bỏ qua số liệu giai đoạn này để JIT và JVM ổn định).
  * Thời gian đo chính thức: `20 giây`.
  * Số lượt lặp lại: Ít nhất `3 lần` cho mỗi kịch bản (1, 10, 50 Clients) để tính giá trị trung bình (Mean) và độ lệch chuẩn (StdDev).

---

## 2. Cấu Trúc Repository

Cấu trúc dự án tuân thủ nghiêm ngặt theo đặc tả Mục 5 của đề bài:

```text
project-root/
├── README.md                                  # Hướng dẫn chi tiết vận hành & tái lập thực nghiệm
├── pom.xml                                    # Cấu hình dự án Maven
├── .gitignore                                 # Loại bỏ triệt để file rác, cache, build outputs
├── src/
│   ├── server/                                # Mã nguồn TCP Server đa luồng (TV1)
│   │   ├── TCPEchoServer.java                 # Lõi Server lắng nghe và điều phối kết nối
│   │   ├── ClientHandler.java                 # Worker xử lý frame nhị phân từ từng client
│   │   └── CpuMonitor.java                    # Luồng nền ghi nhận mức sử dụng CPU của tiến trình
│   ├── load-generator/                        # Ứng dụng tạo tải độc lập (TV2)
│   │   ├── LoadGeneratorApp.java              # Tiến trình tạo tải chính
│   │   ├── BenchmarkWorker.java               # Luồng Client gửi/nhận và đo RTT nano-giây
│   │   └── MetricsCollector.java              # Thu thập, tính toán phân vị RTT và xuất CSV/JSON
│   └── main/java/com/research/common/
│       └── Protocol.java                      # Khai báo hằng số giao thức chung (Header, Body limit)
├── experiments/
│   ├── configs/
│   │   └── benchmark_config.json              # File tham số cấu hình đo lường toàn hệ thống
│   ├── scripts/
│   │   ├── run_benchmarks.ps1                 # Script tự động hóa toàn bộ ma trận đo 3x3 (TV3)
│   │   └── run_validation_tests.ps1           # Script kiểm thử 4 ca kiểm tra chịu lỗi bắt buộc (TV3)
│   ├── raw-data/                              # Nơi lưu trữ toàn bộ dữ liệu CSV/JSON thô đo được
│   ├── analysis/
│   │   └── analyze_data.py                    # Script Python tính toán thống kê (Mean, StdDev) (TV4)
│   └── figures/                               # Chứa 3 biểu đồ độ phân giải cao phục vụ báo cáo (TV4)
│       ├── throughput_vs_clients.png
│       ├── latency_vs_clients.png
│       └── cpu_vs_clients.png
└── docs/
    ├── SUBMISSION_CHECKLIST.md                # Bảng kiểm soát danh mục hồ sơ nộp bài
    └── REPORT.pdf                             # Báo cáo kết quả nghiên cứu học thuật 4–6 trang (TV5 & TV6)
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
*Script sẽ tự động:*
- Biên dịch mã nguồn Java.
- Khởi động `TCPEchoServer` trên cổng `8080`.
- Chạy ma trận 3 mức tải $\times$ 3 lần lặp (1, 10, 50 Clients; mỗi lần 5s warm-up + 20s đo chính thức).
- Ghi dữ liệu thô vào `experiments/raw-data/benchmark_results.csv` và `cpu_metrics.csv`.
- Tự động chạy tiếp 4 ca kiểm thử chịu lỗi (TC1 đến TC4).

> **Mẹo tái lập nhanh (Quick Test):** Để chạy nhanh 1 kịch bản kiểm tra (ví dụ 10 clients, 1 lần lặp, đo 5 giây):
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\experiments\scripts\run_benchmarks.ps1 -Clients 10 -Runs 1 -DurationSec 5 -WarmupSec 2
> ```

### Bước 2: Phân tích số liệu và tự động sinh biểu đồ
Chạy script phân tích dữ liệu:
```bash
python experiments/analysis/analyze_data.py
```
*Script sẽ tính toán Mean, StdDev và tự động xuất ra thư mục `experiments/figures/`:*
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
javac -encoding UTF-8 -d bin src/main/java/com/research/common/*.java src/server/*.java src/load-generator/*.java
```

### 5.2. Khởi động TCP Server (Process 1)
```bash
java -cp bin TCPEchoServer --port 8080
```
*Server sẽ mở Socket lắng nghe tại cổng `8080` và khởi chạy luồng nền giám sát CPU.*

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

* **TC1 (Tải đơn vs Tải cao):** Đo lường tính ổn định và so sánh trực tiếp hiệu năng giữa 1 Client và 50 Clients đồng thời.
* **TC2 (Kiểm chứng tính toàn vẹn dữ liệu):** Đối chiếu chính xác từng byte của `requestId` và `payload` phản hồi so với request gửi đi qua các dải kích thước (0B, 16B, 1KB, 32KB, 64KB) và khi xảy ra phân mảnh luồng TCP.
* **TC3 (Chịu lỗi ngắt kết nối đột ngột):** Khi tải đang chạy tối đa (50 clients), cưỡng bức tắt tiến trình Client (`kill /F` hoặc ngắt nửa frame TCP RST). Kiểm tra xác nhận Server vẫn tiếp tục sống và phản hồi bình thường cho các kết nối mới.
* **TC4 (Xử lý dữ liệu sai / vượt ngưỡng):** Gửi gói tin có `length > 64KB` (vượt `MAX_BODY`) hoặc frame bị rác/cắt cụt phần header. Xác nhận Server đóng kết nối vi phạm an toàn mà không bị crash hoặc treo bộ nhớ.

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
* **Header (4 bytes):** Độ dài $N$ của phần thân body (bằng $8 + \text{Payload length}$).
* **Request ID (8 bytes):** Mã định danh tuần tự của request để đối chiếu tính toàn vẹn.
* **Payload (1024 bytes):** Mảng byte dữ liệu nhị phân.
* **Tổng kích thước 1 Frame chuẩn:** $4 + 8 + 1024 = 1036 \text{ bytes}$.
* **Quy tắc giải mã:** Phía nhận luôn đọc chính xác 4 byte header trước bằng `readFully()`. Nếu $N > 65536$ bytes (`MAX_BODY`), kết nối bị ngắt ngay lập tức để bảo vệ Server.

---

## 8. Công Thức & Chỉ Số Hiệu Năng

Dữ liệu RTT (Round Trip Time) được bấm giờ bằng đồng hồ độ phân giải nano-giây: `System.nanoTime()`.
* **Throughput (req/s):**
  $$\text{Throughput} = \frac{\text{Tổng số request phản hồi thành công}}{\text{Thời gian đo chính thức (20 giây)}}$$
* **Average Latency (ms):**
  $$\text{Avg Latency} = \frac{1}{K} \sum_{i=1}^{K} \text{RTT}_i$$
* **p95 Tail Latency (ms):**
  Sắp xếp danh sách RTT tăng dần, giá trị p95 là phần tử tại vị trí: $\lceil 0.95 \times K \rceil - 1$.
* **Error Rate (%):**
  $$\text{Error Rate} = \frac{\text{Số request lỗi hoặc timeout}}{\text{Tổng số request phát đi}} \times 100$$
* **CPU Usage (%):**
  Lấy từ `OperatingSystemMXBean.getProcessCpuLoad() * 100` ghi nhận định kỳ mỗi giây một lần.

---

## 9. Đóng Gói Hồ Sơ Nộp Bài (Packaging)

Trước khi nộp bài, đảm bảo repository hoàn toàn sạch các file rác biên dịch và cache. Có 2 cách đóng gói nhanh:

### Cách 1: Sử dụng Git Archive (Khuyến nghị - xuất 100% file chuẩn được Git quản lý)
```bash
git archive --format=zip --output="submission_tcp_server_benchmark.zip" HEAD
```

### Cách 2: Sử dụng lệnh PowerShell nén các thư mục quy định
```powershell
Compress-Archive -Path README.md, pom.xml, src, experiments, docs -DestinationPath submission_tcp_server_benchmark.zip -Force
```

> **Lưu ý kiểm tra:** File zip nộp bài chỉ chứa mã nguồn, dữ liệu thực nghiệm, tài liệu hướng dẫn và báo cáo. Tuyệt đối không chứa các thư mục rác `target/`, `bin/`, `.idea/`, `.vscode/` hay `__pycache__/`.

---

## 10. Phân Công Trách Nhiệm Nhóm

| Thành viên | Vai trò phụ trách | Trách nhiệm chính |
| :--- | :--- | :--- |
| **TV1** | **Team Lead** | Xây dựng TCP Server đa luồng, module đo CPU (`CpuMonitor.java`), xử lý an toàn luồng và ngắt kết nối. |
| **TV2** | **Load Generator Lead** | Viết ứng dụng tạo tải nhiều client (`LoadGeneratorApp`), đo RTT nano-giây, tính toán chỉ số thống kê. |
| **TV3** | **Automation & Test Lead** | Tự động hóa chạy thực nghiệm ma trận 3x3 (`run_benchmarks.ps1`), thực thi 4 ca kiểm thử chịu lỗi (TC1–TC4). |
| **TV4** | **Data Analysis Lead** | Viết script Python (`analyze_data.py`), tính toán Mean/StdDev, vẽ 3 biểu đồ chuẩn học thuật 300 DPI. |
| **TV5** | **Lead Research Writer** | Viết nội dung học thuật báo cáo PDF (Mục 1, 2, 5, 6): cơ sở lý thuyết, phân tích kết quả chuyên sâu, kết luận. |
| **TV6** | **Technical Writer & Packaging Lead** | Viết phần kỹ thuật báo cáo (Mục 3, 4, 7, 8), soạn thảo `README.md`, chuẩn hóa repo và đóng gói bài nộp. |

> [!NOTE]
> **Lưu ý về quy mô nhóm:** Đề bài gốc quy định 5 sinh viên/nhóm. Nhóm triển khai với 6 thành viên (TV1 – TV6), đã được phân công rõ ràng từng phân hệ chuyên trách và sẽ đối chiếu xác nhận với Giảng viên phụ trách.
