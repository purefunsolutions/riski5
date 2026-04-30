module riski5_sdram_cdc_bridge (
    // Master side (clkBus domain)
    input  wire        clkBus,
    input  wire        rstBus_n,
    input  wire        m_cs,
    input  wire [21:0] m_addr,
    input  wire [15:0] m_wdata,
    input  wire [1:0]  m_be,
    input  wire        m_rd,
    input  wire        m_wr,
    output reg  [15:0] m_rdata,
    output reg         m_valid,
    output wire        m_waitrequest,

    // Slave side (clkSdram domain) — drives the IP's az_* port
    input  wire        clkSdram,
    input  wire        rstSdram_n,
    output wire        s_cs,
    output wire [21:0] s_addr,
    output wire [15:0] s_wdata,
    output wire [1:0]  s_be,
    output wire        s_rd,
    output wire        s_wr,
    input  wire [15:0] s_rdata,
    input  wire        s_valid,
    input  wire        s_waitrequest,

    // Debug taps for altsource_probe SLD instances at the top
    // level (task #142). All flags / state signals live in
    // their owning clock domain; the probe SLD samples a
    // moment-in-time snapshot that the host reads via JTAG,
    // which is much slower than either clock — so cross-
    // domain races on the snapshot itself don't matter.
    output wire [1:0]  dbg_m_state,
    output wire [1:0]  dbg_s_state,
    output wire        dbg_req_toggle_bus,
    output wire        dbg_done_toggle_sdram,
    output wire [15:0] dbg_cap_rdata_sdram,
    output wire [21:0] dbg_m_lat_addr
);

    // ─── Master-side state ────────────────────────────────────
    localparam [1:0] M_IDLE    = 2'd0;
    localparam [1:0] M_BUSY    = 2'd1;
    localparam [1:0] M_DONE_W  = 2'd2;
    localparam [1:0] M_DONE_R  = 2'd3;

    reg [1:0]  m_state;
    reg [21:0] m_lat_addr;
    reg [15:0] m_lat_wdata;
    reg [1:0]  m_lat_be;
    reg        m_lat_rd;
    reg        m_lat_wr;
    reg        req_toggle_bus;
    reg        done_sync_0, done_sync_1, done_prev_bus;
    wire       done_edge_bus = done_sync_1 ^ done_prev_bus;
    reg [15:0] cap_rdata_sync_0, cap_rdata_sync_1;

    // ─── Slave-side state (forward declared for cross-refs) ──
    reg        done_toggle_sdram;
    reg [15:0] cap_rdata_sdram;

    always @(posedge clkBus or negedge rstBus_n) begin
        if (!rstBus_n) begin
            m_state <= M_IDLE;
            m_lat_addr <= 22'b0;
            m_lat_wdata <= 16'b0;
            m_lat_be <= 2'b0;
            m_lat_rd <= 1'b0;
            m_lat_wr <= 1'b0;
            req_toggle_bus <= 1'b0;
            done_sync_0 <= 1'b0;
            done_sync_1 <= 1'b0;
            done_prev_bus <= 1'b0;
            cap_rdata_sync_0 <= 16'b0;
            cap_rdata_sync_1 <= 16'b0;
            m_rdata <= 16'b0;
            m_valid <= 1'b0;
        end else begin
            // 2-FF synchronise done toggle from clkSdram
            done_sync_0 <= done_toggle_sdram;
            done_sync_1 <= done_sync_0;
            done_prev_bus <= done_sync_1;

            // 2-FF sample cap_rdata from clkSdram. Only meaningful
            // when done_edge fires; otherwise it just tracks the
            // last completed read.
            cap_rdata_sync_0 <= cap_rdata_sdram;
            cap_rdata_sync_1 <= cap_rdata_sync_0;

            // Default: no valid pulse this cycle.
            m_valid <= 1'b0;

            case (m_state)
                M_IDLE: begin
                    if (m_cs) begin
                        m_lat_addr <= m_addr;
                        m_lat_wdata <= m_wdata;
                        m_lat_be <= m_be;
                        m_lat_rd <= m_rd;
                        m_lat_wr <= m_wr;
                        req_toggle_bus <= ~req_toggle_bus;
                        m_state <= M_BUSY;
                    end
                end
                M_BUSY: begin
                    if (done_edge_bus) begin
                        if (m_lat_rd) begin
                            m_rdata <= cap_rdata_sync_1;
                            m_state <= M_DONE_R;
                        end else begin
                            m_state <= M_DONE_W;
                        end
                    end
                end
                M_DONE_W: begin
                    // Drop waitrequest this cycle; back to idle.
                    m_state <= M_IDLE;
                end
                M_DONE_R: begin
                    // waitrequest already dropped this cycle (state
                    // is M_DONE_R, not M_BUSY). The adapter sees
                    // waitrequest=0 and advances to SReadLoWait.
                    // Pulse m_valid in the NEXT cycle (registered),
                    // when adapter is in SReadLoWait and ready to
                    // capture rdata.
                    m_valid <= 1'b1;
                    m_state <= M_IDLE;
                end
                default: m_state <= M_IDLE;
            endcase
        end
    end

    // m_waitrequest is high while a transaction is in flight.
    // Drops in M_DONE_W / M_DONE_R for one cycle so the adapter
    // advances; back to high when M_IDLE if no new cs comes.
    assign m_waitrequest = (m_state == M_BUSY);

    // ─── Slave-side state machine ─────────────────────────────
    localparam [1:0] S_IDLE        = 2'd0;
    localparam [1:0] S_REQ         = 2'd1;
    localparam [1:0] S_AWAIT_VALID = 2'd2;
    localparam [1:0] S_DONE        = 2'd3;

    reg [1:0]  s_state;
    reg        req_sync_0_sdr, req_sync_1_sdr, req_prev_sdr;
    wire       req_edge_sdr = req_sync_1_sdr ^ req_prev_sdr;
    reg [21:0] s_lat_addr_buf;
    reg [15:0] s_lat_wdata_buf;
    reg [1:0]  s_lat_be_buf;
    reg        s_lat_rd_buf;
    reg        s_lat_wr_buf;

    always @(posedge clkSdram or negedge rstSdram_n) begin
        if (!rstSdram_n) begin
            s_state <= S_IDLE;
            req_sync_0_sdr <= 1'b0;
            req_sync_1_sdr <= 1'b0;
            req_prev_sdr <= 1'b0;
            done_toggle_sdram <= 1'b0;
            cap_rdata_sdram <= 16'b0;
            s_lat_addr_buf <= 22'b0;
            s_lat_wdata_buf <= 16'b0;
            s_lat_be_buf <= 2'b0;
            s_lat_rd_buf <= 1'b0;
            s_lat_wr_buf <= 1'b0;
        end else begin
            // 2-FF synchronise req toggle from clkBus
            req_sync_0_sdr <= req_toggle_bus;
            req_sync_1_sdr <= req_sync_0_sdr;
            req_prev_sdr <= req_sync_1_sdr;

            case (s_state)
                S_IDLE: begin
                    if (req_edge_sdr) begin
                        // Sample latched signals from master domain.
                        // Stable because master holds them in M_BUSY.
                        s_lat_addr_buf <= m_lat_addr;
                        s_lat_wdata_buf <= m_lat_wdata;
                        s_lat_be_buf <= m_lat_be;
                        s_lat_rd_buf <= m_lat_rd;
                        s_lat_wr_buf <= m_lat_wr;
                        s_state <= S_REQ;
                    end
                end
                S_REQ: begin
                    // Drive IP. Wait for !waitrequest to advance.
                    if (!s_waitrequest) begin
                        if (s_lat_rd_buf) begin
                            s_state <= S_AWAIT_VALID;
                        end else begin
                            s_state <= S_DONE;
                        end
                    end
                end
                S_AWAIT_VALID: begin
                    if (s_valid) begin
                        cap_rdata_sdram <= s_rdata;
                        s_state <= S_DONE;
                    end
                end
                S_DONE: begin
                    done_toggle_sdram <= ~done_toggle_sdram;
                    s_state <= S_IDLE;
                end
                default: s_state <= S_IDLE;
            endcase
        end
    end

    // Drive IP slave port combinationally from the latched-and-
    // held registers when in S_REQ. Outside S_REQ the strobes
    // (cs / rd / wr) go inactive so the IP sees a clean idle
    // between transactions; address / wdata / be can keep their
    // last value (the IP only samples them on cs+!waitrequest).
    assign s_cs    = (s_state == S_REQ);
    assign s_addr  = s_lat_addr_buf;
    assign s_wdata = s_lat_wdata_buf;
    assign s_be    = s_lat_be_buf;
    assign s_rd    = (s_state == S_REQ) & s_lat_rd_buf;
    assign s_wr    = (s_state == S_REQ) & s_lat_wr_buf;

    // Debug taps for top-level altsource_probe SLD nodes.
    assign dbg_m_state           = m_state;
    assign dbg_s_state           = s_state;
    assign dbg_req_toggle_bus    = req_toggle_bus;
    assign dbg_done_toggle_sdram = done_toggle_sdram;
    assign dbg_cap_rdata_sdram   = cap_rdata_sdram;
    assign dbg_m_lat_addr        = m_lat_addr;

endmodule
