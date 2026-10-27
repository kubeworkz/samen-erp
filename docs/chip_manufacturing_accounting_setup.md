Setting up accounting books for a chip manufacturing company requires a highly specialized approach that differs significantly from general manufacturing. The core challenge lies in the complexity of the production process, which involves multi-stage workflows, significant work-in-process (WIP), and the need for granular cost tracking by project, batch, and process.

Here is a structured guide to establishing your accounting framework, covering the critical decisions you need to make.

### 🏭 First, Clarify Your Business Model

Your accounting setup depends heavily on whether you are a **Foundry (Fab)**, an **Integrated Device Manufacturer (IDM)**, or a **Fabless** design company. The key difference is where the physical manufacturing occurs.

- **Foundry & IDM (In-House Manufacturing)**: You own the fabs and equipment. Your books must handle massive fixed assets, complex depreciation, and detailed production cost accounting for every wafer lot.
- **Fabless (Outsourced Manufacturing)**: You design chips and outsource fabrication (to a Foundry) and packaging/testing (to an OSAT). Your books focus on managing **subcontracting costs**, tracking **consigned inventory**, and accounting for **work-in-progress (WIP)** held by suppliers.

The following sections focus primarily on the **in-house manufacturing model**, as it presents the most complex accounting requirements.

### 📒 Designing Your Chart of Accounts (COA)

A generic COA will not work for a chip manufacturer. You need to build out the inventory, COGS, and expense sections to capture the industry's unique cost drivers.

**Key COA Modifications for Chip Manufacturing:**

- **Inventory (1000s/1200s)**: Split this into three distinct accounts as required by GAAP:
  - **Raw Materials**: Silicon wafers, chemicals, photoresists, gases, and spare parts.
  - **Work-in-Process (WIP)**: This is the critical account. It should track the value of wafers at various stages of fabrication (e.g., after lithography, after etching) and chips in packaging/test. Your system should ideally track WIP by lot and process step.
  - **Finished Goods**: Completed, tested chips ready for sale.
- **Cost of Goods Sold (5000s)**: Break this down into granular accounts:
  - **Direct Materials**: Cost of silicon wafers and other materials directly consumed.
  - **Direct Labor**: Wages of operators directly running the fab equipment.
  - **Manufacturing Overhead**: This is the largest cost bucket. Create separate accounts for:
    - **Equipment Depreciation**: The single largest cost in a fab.
    - **Facility Costs**: Cleanroom power, ultrapure water, and gas systems.
    - **Indirect Labor**: Process engineers, maintenance technicians, and quality control staff.
    - **Yield & Scrap**: A dedicated account to track the cost of defective wafers and chips. This is a key metric in semiconductor manufacturing.
- **Operating Expenses (6000s)**:
  - **Research & Development (R&D)**: Separate accounts for **Mask (Reticle) Costs**, **EDA Software Licenses**, and **IP Licensing Fees**. These can be substantial and must be tracked carefully for both management and tax purposes.

### 💰 Core Accounting Policies: Inventory & Costing

Your inventory valuation and cost accounting methods are the heart of your books.

**1. Inventory Valuation Method**  

You must choose a cost flow assumption. Common methods in the industry are:

- **Standard Costing**: Many manufacturers use this. You set a "standard" cost for each product and track **variances** (differences between standard and actual costs) for materials, labor, and overhead. This allows for quick valuation but requires regular revaluation.
- **Weighted Average Cost**: Costs are averaged over all units in inventory. This is simpler to maintain but can be less precise for decision-making.
- **First-In, First-Out (FIFO)**: Assumes older inventory is sold first. This can be complex to track in a fab environment but is used by some companies.

**2. Cost Accumulation**  

The system must be able to accumulate costs by **project, batch (lot), process step, and machine**. This is essential for calculating the true cost of each chip and for analyzing yield and profitability.

**3. Inventory Write-Downs**  

Semiconductor inventory is subject to rapid obsolescence. You must establish a policy to regularly assess inventory for excess and obsolete stock and write it down to its **Net Realizable Value (NRV)**. A common policy is to write down wafers that have been held for a certain period (e.g., older than two or three years).

### 💻 Technology & Software Requirements

You cannot manage this on a basic accounting package like QuickBooks. You need a robust **ERP (Enterprise Resource Planning) system** with specific semiconductor functionality.

**Key Functional Requirements:**

- **Lot/Batch Traceability**: The system must support **five-level traceability**: from wafer lot to individual wafer, to assembly batch, to finished unit serial number, and finally to the customer shipment.
- **Complex Costing**: It must handle **process costing** and **standard costing** with variance analysis, and be able to roll up costs through multiple process steps.
- **Subcontracting Management**: For Fabless and hybrid models, the system must manage the entire outsourced chain: issuing materials, tracking WIP at the supplier, reconciling leftover materials, and settling processing fees.
- **Multi-Entity Consolidation**: If you have separate legal entities for design, manufacturing, and sales, the ERP must support multi-organization accounting and intercompany transactions.

**Examples of Suitable Systems:**

- **Tier 1**: SAP S/4HANA, Oracle Cloud ERP (with industry-specific modules).
- **Tier 2 / Industry-Specific**: Tensoft SemiOps (designed specifically for fabless semiconductor companies), Yonyou BIP (IC Chip Industry Solution).
- **Tier 3**: Microsoft Dynamics 365 Business Central (often paired with an industry-specific add-on for semiconductor supply chain management).

### 💎 Summary & Key Takeaways

Setting up accounting for a chip manufacturer is a project that requires a deep understanding of both accounting principles and the semiconductor production process.

1. **Define Your Model**: Your entire accounting architecture flows from whether you are a Foundry/IDM or a Fabless company.
2. **Build a Specialized COA**: Don't use a generic template. Create detailed accounts for WIP, manufacturing overhead, and yield/scrap.
3. **Choose Your Costing Method**: Decide between standard costing (for control and variance analysis) and weighted average (for simplicity).
4. **Invest in the Right ERP**: A standard ERP will fail. You need a system with native support for lot traceability, process costing, and subcontracting management.
5. **Establish Clear Policies**: Document your rules for inventory valuation, capitalization of R&D costs, and obsolete inventory write-downs from the start.

I hope this guide provides a solid foundation for your project. If you can share more details about your specific business model (e.g., Fabless vs. IDM) or the stage of your company, I can offer more targeted considerations.

---

# Fabless Business Model

This is a very specific and exciting business model. Moving from a general chip manufacturer to a **fabless, AI-driven design house** focused on **research and academia** fundamentally changes your accounting priorities. The core challenge shifts from managing massive fixed assets to meticulously tracking **intangible development costs**, **subcontractor relationships**, and a **unique revenue model**.

Here is how to tailor your accounting setup for this specific venture.

### 🎯 Your Business Model & Its Accounting Implications

You are a **Fabless Semiconductor Company**. This means you outsource all physical manufacturing. Your balance sheet will be "asset-light" regarding physical plant, but "cost-heavy" regarding R&D and intellectual property.

- **Key Partners**:
  - **GlobalFoundries (GF)**: Your primary foundry partner for chip fabrication, likely using their Multi-Project Wafer (MPW) program (GlobalShuttle) for prototyping.
  - **[wafer.space](https://wafer.space/)**: An intermediary that pools designs for MPW runs, often using GF's processes (e.g., GF180MCU). They handle the coordination, dicing, and shipping, which simplifies your supply chain but adds a layer of cost to track.
  - **Photonics Partner (TBD)**: You will need to select a foundry or research institute with silicon photonics capabilities. Accounting for this will be similar to your GF relationship but may involve specific NRE (Non-Recurring Engineering) charges for process development.

### 📒 Chart of Accounts (COA) for a Fabless AI Chip Company

Your COA must be built to capture the costs of **design**, **prototyping**, and **intellectual property**.

**1. Inventory (Assets)**  

You have no raw materials. Your inventory is **Work-in-Process (WIP)** held at your subcontractors.

- **1200 · WIP – Foundry (GlobalFoundries/[wafer.space](https://wafer.space/))**: The value of your wafers currently being fabricated. This will be your largest inventory account during production runs.
- **1210 · WIP – Photonics Partner**: Separate tracking for your photonic chip fabrication.
- **1220 · WIP – Assembly & Test (OSAT)**: Once wafers are diced and packaged, the value moves here.
- **1230 · Finished Goods – Development Boards**: The final, assembled development boards ready for sale.

**2. Cost of Goods Sold (COGS)**

- **5000 · Direct Foundry Costs**: The cost of the MPW slot or wafer fabrication.
- **5010 · Direct Photonics Costs**: Costs paid to your photonics foundry.
- **5020 · Assembly & Test Costs**: Fees paid to your OSAT partner.
- **5030 · [Wafer.space](https://wafer.space/) Coordination Fees**: The service fees paid to [wafer.space](https://wafer.space/) for pooling, dicing, and logistics.
- **5040 · Development Board BOM (Bill of Materials)**: Cost of PCBs, connectors, passive components, and the cost of your own finished chips that are mounted onto the boards.

**3. Research & Development (Operating Expenses)**  

This is where you will track the cost of your AI-driven design process.

- **6000 · R&D – Mask & Reticle Costs**: The cost of creating the photomasks for your MPW runs. These are typically expensed as incurred for R&D purposes.
- **6010 · R&D – EDA Software & IP Licensing**: The cost of your AI design tools, simulation software, and any third-party IP cores you license.
- **6020 · R&D – Design Engineering Labor**: Salaries of your chip designers and AI engineers.
- **6030 · R&D – Prototype & Test Engineering**: Costs for testing and validating your first silicon.

### 💰 Core Accounting Policies & Workflows

**1. Accounting for MPW Shuttles (GlobalFoundries & [wafer.space](https://wafer.space/))**

- **The Cost**: When you purchase an MPW slot (e.g., via [wafer.space](https://wafer.space/) for ~$2,000 or a direct GF shuttle), you are paying for a fraction of a wafer and a share of the mask set cost. This is a direct R&D cost for a prototype.
- **The Accounting Entry**:
  - **Debit**: R&D – Mask & Reticle Costs (for the mask portion) and R&D – Prototype & Test Engineering (for the wafer portion).
  - **Credit**: Cash / Accounts Payable.
- **The Inventory Entry**: When the chips are received, they have a cost basis. For a development board, you would **capitalize** the MPW cost into the inventory of that board. If the chips are solely for internal R&D testing, the cost remains in R&D expense.

**2. Accounting for Photonics Design**  

Silicon photonics often involves **Activity-Based Costing (ABC)** because the manufacturing process is highly specialized. You will need to work with your photonics partner to understand the cost drivers (e.g., number of lithography steps, epitaxial material cost) and track your design's consumption of those activities.

**3. Revenue Recognition for Development Boards**  

Selling to research organizations and academia is different from commercial sales. Universities often have strict procurement and grant-funding rules.

- **Performance Obligation**: The sale of a development board is a distinct performance obligation.
- **Timing**: Revenue is typically recognized **at a point in time** when control transfers to the university. This is usually upon **shipment or delivery**, depending on the terms of the purchase order.
- **Special Consideration**: If the board is sold as part of a research grant or contract, you may need to follow **ASC 606** and potentially defer revenue if there are ongoing performance obligations (e.g., providing technical support for the duration of a research project). Ensure your sales agreements with universities clearly define the deliverables.

### 💻 ERP & Software Requirements

You do not need a full manufacturing ERP. You need a **Fabless Semiconductor Management System** integrated with a modern accounting core.

- **Recommended Solution**: **Tensoft SemiOps**. It is purpose-built for fabless semiconductor companies. It integrates with accounting systems like **NetSuite** or **Microsoft Dynamics 365 Business Central**. This solution is designed to handle the exact complexities you face: MPW lot tracking, unit-of-measure conversions from wafer to die, and managing subcontractor WIP. A case study on Luxtera, a silicon photonics fabless company, is a perfect example of this setup.
- **AI Design Cost Tracking**: Your AI design tools (e.g., for RTL generation and verification) will likely be cloud-based subscriptions. Track these as **R&D – EDA Software & IP Licensing**. If your AI is used to generate IP that you sell or license, you may need to capitalize some of those development costs.

### 💎 Summary of Key Accounting Policies for Your Setup

1. **Capitalization Policy**: Establish a clear policy for when you capitalize costs (e.g., when a development board project reaches "technological feasibility") versus when you expense them as R&D.
2. **MPW Cost Allocation**: Define a methodology for allocating the cost of a single MPW shuttle across multiple chip designs or development board projects.
3. **Subcontractor Reconciliation**: Implement a rigorous process for reconciling WIP at GF and [wafer.space](https://wafer.space/). You must regularly confirm the quantity of your die on their wafers and the associated costs.
4. **Grant & Contract Accounting**: If you receive any government or institutional grants for your development boards, you will need a separate fund accounting structure to track restricted revenue and expenses, ensuring compliance with the grant's terms.

This structure will give you the granular data you need to manage your AI design process, your critical foundry partnerships, and your unique customer base.

---

# Global Foundaries Photonics Fab

Yes, GlobalFoundries (GF) has significant silicon photonics manufacturing capabilities. In fact, they are currently positioning themselves as a leader in this space.

Here is a breakdown of their photonics fab operations based on their public announcements:

### 🏭 GF's Silicon Photonics Fab Locations

**1. Malta, New York (USA)**  

GF's primary silicon photonics manufacturing is integrated directly into their existing CMOS fab in Malta, NY. They achieve this by reusing **more than 90% of the standard CMOS toolset** for photonics, adding only a few dedicated modules for specialized steps like advanced modulators or laser integration. This approach allows them to leverage mature process control and high-volume manufacturing practices.

**2. Singapore (via Advanced Micro Foundry)**  

In November 2025, GF **acquired Advanced Micro Foundry (AMF)**, a Singapore-based pure-play silicon photonics foundry. This acquisition made GF the **largest pure-play silicon photonics foundry by revenue**. The Singapore site operates on a 200mm platform (with plans to scale to 300mm) and focuses on long-reach optical communications, computing, LiDAR, and sensing applications.

### 🔗 Relevant Foundry Services for Your Photonics Design

For your photonics development work, there are two GF-related options worth noting:

- **GF's Internal Silicon Photonics Platform**: GF offers a production-proven silicon photonics platform directly, which supports pluggable optics and co-packaged optics for AI data centers. This is built on their scalable CMOS-compatible process.
- **Open Access Service with SMART Photonics**: In September 2026, GF partnered with **SMART Photonics** to offer the industry's first **open access foundry service** combining GF's silicon platform with SMART Photonics' indium phosphide (InP) PICs. This service integrates lasers and semiconductor optical amplifiers (SOAs) into GF's silicon cavities using flip-chip technology. General availability is targeted for **the second half of 2027**.

### 💡 What This Means for Your Accounting Setup

Since you are still deciding on a photonics partner, this information has a direct impact on your books:

- **If you use GF directly for photonics**: Your WIP and COGS accounts for photonics can be structured similarly to your GF foundry accounts for your AI chips. You would track costs under a **"WIP – Photonics (GlobalFoundries)"** account.
- **If you use the GF/SMART Photonics open access service**: Your photonics costs may be split between **GF (silicon fabrication)** and **SMART Photonics (InP laser integration)**. You would need separate WIP or cost accounts for each partner to properly track the value chain.
- **If you choose a different photonics foundry**: Your COA should still have a dedicated **"WIP – Photonics Partner"** account, regardless of which fab you ultimately select.

GF clearly has the photonics infrastructure in place, both in the US and Singapore. The main decision for you is whether to engage them directly for silicon photonics or wait for the open access service with SMART Photonics to become available.

---

# Fab Manifest

Here are examples for each of the four terms you asked about, drawn from actual foundry MPW programs and commercial agreements. Since you're working with GlobalFoundries and [wafer.space](https://wafer.space/), I've anchored the examples to their documented practices wherever possible.

---

### 🎫 Slot/Order

This term describes the **reservation mechanism** you use to secure a position on a shared wafer run. In an MPW context, a "slot" is a defined die area on the reticle, and purchasing a slot is the commercial act that reserves your design's place in a specific shuttle.

**Examples:**

- **[wafer.space](https://wafer.space/) GF180MCU Run 3**: "Price: Starting from **$2,000 USD per slot**. Die Size: Up to 3.88mm × 5.07mm (~20mm²). Quantity: 1,000 chips per slot." The slot purchase deadline is **09 Dec 2026**, and the design submission deadline follows on **16 Dec 2026**.
- **[wafer.space](https://wafer.space/) GF180MCU Run 2**: Offers "half-width and half-height slot options starting at **$4,000**, stricter DRC checking, and an improved submission platform."
- **ChipFoundry chipIgnite**: A **$500 USD non-refundable deposit** secures a reservation. This deposit is applied to the total project cost.
- **GlobalFoundries GlobalShuttle**: For AMF photonics shuttles, "Please submit GDS by **15th of the previous month** to secure a slot in the shuttle. Max 3 DRC iterations by AMF."

**Accounting implication**: A slot purchase is typically a **prepayment or deposit** recorded as a current asset (Prepaid Foundry Costs) until the design is submitted and fabrication begins. The deposit portion may be non-refundable, requiring careful tracking of recoverability.

---

### 📅 Schedule

The schedule defines the **critical deadlines** for your project. For MPW runs, the schedule is fixed and non-negotiable—missing a deadline means your design defers to the next shuttle, often by a full quarter.

**Examples:**

- **[wafer.space](https://wafer.space/) GF180MCU Run 3 (documented timeline)**:
  <table>
    <tr><th>Milestone</th><th>Date</th></tr>
    <tr><td>Slot purchase deadline</td><td>09 Dec 2026</td></tr>
    <tr><td>Design submission deadline</td><td>16 Dec 2026</td></tr>
    <tr><td>Chip delivery</td><td>Q2 2027</td></tr>
  </table>

- **GlobalFoundries GlobalShuttle 2026/2027**: GF publishes a multi-month platform-specific schedule spanning **OCT through DEC of the following year**, with columns for each month indicating shuttle tapeout months for platforms including 12nm, 22nm, 180nm, and the **AMF MPW (photonics)** line.
- **GlobalFoundries AMF photonics-specific**: "Max 3 DRC iterations by AMF. Any DRC violation must be waived by this date."
- **TSRI (Taiwan) MPW schedule**: Lists distinct deadlines for **Educational Chip**, **Advanced Chip**, and file upload, with MPW runs following a quarterly cycle. Late submissions may be deferred to the next round.

**Accounting implication**: Schedule milestones drive **revenue recognition** for any grant-funded work and **expense timing** for R&D costs. A missed deadline that defers fabrication to a later quarter may push costs into a different fiscal period.

---

### 📜 Commercial Terms

These are the **pricing, payment, liability, and IP provisions** that govern your relationship with the foundry or intermediary.

**Examples from ChipFoundry chipIgnite (a comparable MPW commercial agreement):**

**Pricing:**

- Base price: **$14,950 USD** per standard project, including fabrication of one design, **100 QFN packaged parts**, 10 parts on M.2 daughter cards, a standard evaluation board, and test firmware.
- Additional 50 bare die beyond the standard 100: **$3,000 USD**.
- Academic discounts available for qualified educational institutions; volume discounts for multiple designs.

**Payment Schedule:**

- Initial deposit: **$500 USD** due at reservation.
- First milestone: **50% of remaining balance** due **60 days before** shuttle submission deadline.
- Final payment: **remaining balance** due **14 days before** shuttle submission deadline.

**Key Legal Provisions:**

- **Minimum Customer Threshold**: A shuttle will only proceed if a minimum number of committed projects is met. ChipFoundry may reschedule or cancel if the threshold is not met.
- **Design Rejection Rights**: ChipFoundry "is not obligated to review, test, or validate Customer's submission but reserves the right to reject any design."
- **Late Payment**: May result in project cancellation or removal from the scheduled shuttle.

**GlobalFoundries-specific terms:**

- GF reserves the right to **modify the MPW plan** in support of customers.
- **AMF photonics shuttles** require GDS submission by the 15th of the previous month, with a maximum of 3 DRC iterations permitted.

**Accounting implication**: The payment schedule creates **milestone-based cash outflows** that must be matched against the WIP inventory account as fabrication progresses. The minimum threshold clause introduces **contingency**—if a shuttle is cancelled, your deposit and any prepayments may be at risk.

---

### 🛣️ Route-Specific Submission Details

This term refers to the **technical and procedural requirements specific to the fabrication route** you've selected—essentially, what you must submit, in what format, and through which channel.

**Examples:**

- **[wafer.space](https://wafer.space/) / GF180MCU route**:
  - **Design submission**: GDS file via the [wafer.space](https://wafer.space/) submission platform.
  - **PDK**: GF180MCU open-source PDK.
  - **Project template**: A dedicated `gf180mcu-project-template` repository is provided for MPW runs using this PDK.
  - **Deliverable**: Bare dies or chip-on-board, 1,000 chips per slot.
- **GlobalFoundries AMF photonics route**:
  - **File format**: GDS.
  - **Submission deadline**: 15th of the previous month.
  - **DRC requirement**: Maximum 3 DRC iterations; any violation must be **waived by the submission deadline**.
  - **Additional documentation**: Brochure available for AMF shuttles with further submission details.
- **Europractice / GlobalFoundries route**:
  - **Access mechanism**: Through EUROPRACTICE, customers from academic and private sectors can access GF's MPW and volume production services for technologies including **ASICs, Photonics, MEMS, and more**.
  - **Order form**: A **CMP Order Form** must be completed, and packaging must be ordered before the run deadline. A bonding diagram must accompany the order form for wire-bond packaging.
- **Samsung Foundry MPW route** (for comparison):
  - **B2B CONNECT service**: Existing customers submit project details on the CONNECT website including **chip size, metal specifications, and number of sample wafers needed**, then follow the directions to complete the application.

**Accounting implication**: Route-specific requirements determine **when costs are incurred**. For example, a route requiring a bonding diagram and separate packaging order before the run deadline means you'll have a **packaging cost commitment** earlier in the cycle than a route that bundles packaging into the base fee. Your COA should have separate accounts for **foundry fabrication**, **dicing**, and **packaging** to track these distinct cost pools accurately.

---

### 📋 Putting It Together: A Fab Manifest Template

Based on these examples, a fab manifest for your project might look like this:

<table>
  <tr><th>Field</th><th>Example Entry</th></tr>
  <tr><td>Slot/Order</td><td>wafer.space GF180MCU Run 3, 1 slot, $2,000, die size 3.88mm × 5.07mm</td></tr>
  <tr><td>Schedule</td><td>Slot purchase: 09 Dec 2026; GDS submission: 16 Dec 2026; Delivery: Q2 2027</td></tr>
  <tr><td>Commercial Terms</td><td>50% at reservation + 50% at 60 days pre-submission; $500 deposit; minimum threshold applies</td></tr>
  <tr><td>Route-Specific Submission</td><td>GF180MCU PDK; GDS via wafer.space platform; project template repo required; bare die delivery</td></tr>
</table>

---

# Project Overview

<table>
  <tr><th>Attribute</th><th>Detail</th></tr>
  <tr><td>Project Name</td><td>AI-Driven RISC-V64 + GPU + PTA Development Board (PDB)</td></tr>
  <tr><td>Chips</td><td>Quad-core RISC-V64 SoC with NPU (&quot;RISC-V64 SoC&quot;), Full GPU (&quot;GPU&quot;), Photonics Tensor Accelerator (&quot;PTA&quot;)</td></tr>
  <tr><td>Fabrication Partners</td><td>wafer.space (RISC-V64 SoC, GPU via GF180MCU MPW); GlobalFoundries / AMF (PTA via photonics MPW)</td></tr>
  <tr><td>Target Customer</td><td>Research organizations and academia</td></tr>
  <tr><td>Design Methodology</td><td>AI-assisted RTL generation and verification</td></tr>
</table>

---

## Chip 1: Quad-Core RISC-V64 SoC with NPU

### 🎫 Slot/Order

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Program</td><td>wafer.space GF180MCU Run 3</td></tr>
  <tr><td>Process</td><td>GF180MCU open-source PDK (180nm)</td></tr>
  <tr><td>Slot Type</td><td>1×1 full slot</td></tr>
  <tr><td>Die Size</td><td>Up to 3.88mm × 5.07mm (~19.67mm²)</td></tr>
  <tr><td>Quantity</td><td>1,000 chips per slot</td></tr>
  <tr><td>Slot Price</td><td>Starting from $2,000 USD per slot (early bird); standard pricing $8,000</td></tr>
  <tr><td>Packaging</td><td>Bare die or chip-on-board (+$1,500 add-on)</td></tr>
</table>

### 📅 Schedule

<table>
  <tr><th>Milestone</th><th>Date</th></tr>
  <tr><td>Slot purchase deadline</td><td>09 Dec 2026</td></tr>
  <tr><td>Design submission deadline</td><td>16 Dec 2026</td></tr>
  <tr><td>Chip delivery</td><td>Q2 2027</td></tr>
</table>

### 📜 Commercial Terms

<table>
  <tr><th>Term</th><th>Detail</th></tr>
  <tr><td>Pricing</td><td>Early bird: $2,000/slot; Standard: $8,000/slot ($7/die)</td></tr>
  <tr><td>Payment</td><td>Full payment at slot purchase</td></tr>
  <tr><td>Minimum Threshold</td><td>Shuttle proceeds only if minimum demand fulfilled</td></tr>
  <tr><td>Late Submission</td><td>Design deferred to next shuttle run</td></tr>
  <tr><td>Deliverable</td><td>1,000 bare dies or chip-on-board</td></tr>
</table>

### 🛣️ Route-Specific Submission Details

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>PDK</td><td>GF180MCU open-source PDK</td></tr>
  <tr><td>File Format</td><td>GDS or OASIS (compressed files supported: .zip, .gz, .tar.bz2)</td></tr>
  <tr><td>Submission Platform</td><td>wafer.space submission platform</td></tr>
  <tr><td>Project Template</td><td>gf180mcu-project-template repository required</td></tr>
  <tr><td>Checksums</td><td>Uncompressed GDS/OASIS file checksums required</td></tr>
  <tr><td>Design Rules</td><td>DRC checks performed automatically by wafer.space</td></tr>
</table>

### 📒 Accounting Journal Entries

<table>
  <tr><th>Event</th><th>Debit</th><th>Credit</th><th>Amount</th></tr>
  <tr><td>Slot purchase (early bird)</td><td>Prepaid Foundry Costs (Asset)</td><td>Cash / AP</td><td>$2,000</td></tr>
  <tr><td>Design submission</td><td>WIP – Foundry (wafer.space)</td><td>Prepaid Foundry Costs</td><td>$2,000</td></tr>
  <tr><td>Chip delivery received</td><td>Inventory – Finished Goods (RISC-V64 SoC)</td><td>WIP – Foundry</td><td>$2,000</td></tr>
  <tr><td>Chip-on-board add-on</td><td>Inventory – Finished Goods</td><td>Cash / AP</td><td>$1,500</td></tr>
</table>

---

## Chip 2: Full GPU Chip

### 🎫 Slot/Order

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Program</td><td>wafer.space GF180MCU Run 3</td></tr>
  <tr><td>Process</td><td>GF180MCU open-source PDK (180nm)</td></tr>
  <tr><td>Slot Type</td><td>1×1 full slot (requires larger area for GPU)</td></tr>
  <tr><td>Die Size</td><td>Up to 3.88mm × 5.07mm (~19.67mm²) per slot; GPU may require multiple slots or a larger custom arrangement</td></tr>
  <tr><td>Quantity</td><td>1,000 chips per slot</td></tr>
  <tr><td>Slot Price</td><td>Starting from $2,000 USD per slot</td></tr>
  <tr><td>Packaging</td><td>Bare die or chip-on-board</td></tr>
</table>

> **Note**: A full GPU chip may exceed the standard 1×1 slot area. If so, you would need to purchase **multiple slots** and arrange for reticle stitching or a larger die. [wafer.space](https://wafer.space/)'s reticle stitcher integration supports this use case .

### 📅 Schedule

<table>
  <tr><th>Milestone</th><th>Date</th></tr>
  <tr><td>Slot purchase deadline</td><td>09 Dec 2026</td></tr>
  <tr><td>Design submission deadline</td><td>16 Dec 2026</td></tr>
  <tr><td>Chip delivery</td><td>Q2 2027</td></tr>
</table>

### 📜 Commercial Terms

<table>
  <tr><th>Term</th><th>Detail</th></tr>
  <tr><td>Pricing</td><td>$2,000–$8,000 per slot (depending on early bird/standard)</td></tr>
  <tr><td>Multi-Slot Pricing</td><td>2× slots would be approximately $4,000–$16,000</td></tr>
  <tr><td>Payment</td><td>Full payment at slot purchase</td></tr>
  <tr><td>Deliverable</td><td>Bare dies or chip-on-board</td></tr>
</table>

### 🛣️ Route-Specific Submission Details

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>PDK</td><td>GF180MCU open-source PDK</td></tr>
  <tr><td>File Format</td><td>GDS or OASIS</td></tr>
  <tr><td>Multi-Slot Stitching</td><td>Reticle stitcher integration required for designs spanning multiple slots</td></tr>
  <tr><td>Design Rules</td><td>DRC checks; reticle stitching constraints apply</td></tr>
  <tr><td>Project Template</td><td>gf180mcu-project-template with stitching modifications</td></tr>
</table>

### 📒 Accounting Journal Entries

<table>
  <tr><th>Event</th><th>Debit</th><th>Credit</th><th>Amount</th></tr>
  <tr><td>Slot purchase (2× slots)</td><td>Prepaid Foundry Costs</td><td>Cash / AP</td><td>$4,000–$16,000</td></tr>
  <tr><td>Design submission</td><td>WIP – Foundry (wafer.space)</td><td>Prepaid Foundry Costs</td><td>Same</td></tr>
  <tr><td>Chip delivery received</td><td>Inventory – Finished Goods (GPU)</td><td>WIP – Foundry</td><td>Same</td></tr>
</table>

---

## Chip 3: Photonics Tensor Accelerator (PTA)

### 🎫 Slot/Order

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Program</td><td>GlobalFoundries GlobalShuttle – AMF MPW (photonics)</td></tr>
  <tr><td>Process</td><td>AMF silicon photonics platform</td></tr>
  <tr><td>Access</td><td>Commercial; quote required</td></tr>
  <tr><td>PDK State</td><td>Technology agreement and PDK access required</td></tr>
</table>

### 📅 Schedule

<table>
  <tr><th>Milestone</th><th>Date</th></tr>
  <tr><td>Shuttle Run Months</td><td>Per GlobalShuttle schedule; AMF MPW runs are indicated in the 2026–2027 schedule</td></tr>
  <tr><td>GDS Submission Deadline</td><td>15th of the previous month to secure a slot</td></tr>
  <tr><td>DRC Iterations</td><td>Maximum 3 DRC iterations by AMF</td></tr>
  <tr><td>DRC Waiver Deadline</td><td>Any DRC violation must be waived by the submission deadline</td></tr>
</table>

### 📜 Commercial Terms

<table>
  <tr><th>Term</th><th>Detail</th></tr>
  <tr><td>Pricing</td><td>Quote required (not publicly listed)</td></tr>
  <tr><td>Access Model</td><td>Commercial</td></tr>
  <tr><td>Confidentiality</td><td>Design and PDK data remain controlled by providers</td></tr>
  <tr><td>IP Terms</td><td>Technology agreement required</td></tr>
</table>

### 🛣️ Route-Specific Submission Details

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Platform</td><td>AMF silicon photonics platform (acquired by GF)</td></tr>
  <tr><td>File Format</td><td>GDS</td></tr>
  <tr><td>Submission Mode</td><td>Official photonics MPW intake</td></tr>
  <tr><td>PDK Access</td><td>Technology agreement and PDK access required</td></tr>
  <tr><td>DRC</td><td>Max 3 iterations; violations must be waived by submission deadline</td></tr>
  <tr><td>Brochure</td><td>AMF shuttle brochure available from GF</td></tr>
</table>

### 💡 PTA Design Considerations

Your PTA design will implement a matrix-vector multiplier on the silicon photonics platform . GF's photonics platforms include **90WG** (photonics-optimized 90nm CMOS) and **45CLO** (45nm monolithic electronics-photonics) . The AMF platform provides a production-proven silicon photonics process accessible through the GlobalShuttle MPW program.

### 📒 Accounting Journal Entries

<table>
  <tr><th>Event</th><th>Debit</th><th>Credit</th><th>Amount</th></tr>
  <tr><td>Quote and technology agreement</td><td>Prepaid Photonics Costs (Asset)</td><td>Cash / AP</td><td>Quote amount</td></tr>
  <tr><td>GDS submission</td><td>WIP – Photonics (GF/AMF)</td><td>Prepaid Photonics Costs</td><td>Same</td></tr>
  <tr><td>Chip delivery received</td><td>Inventory – Finished Goods (PTA)</td><td>WIP – Photonics</td><td>Same</td></tr>
</table>

---

## Development Board (PDB) Assembly

### 🎫 Order Details

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Board Name</td><td>PDB – AI Development Board</td></tr>
  <tr><td>Components</td><td>RISC-V64 SoC + GPU + PTA chips, PCB, passives, connectors, power management</td></tr>
  <tr><td>Chip Sources</td><td>Internal inventory (from MPW runs)</td></tr>
  <tr><td>PCB Fabrication</td><td>External vendor (NRE costs)</td></tr>
</table>

### 📅 Schedule

<table>
  <tr><th>Milestone</th><th>Date</th></tr>
  <tr><td>Chip delivery (all three)</td><td>Q2 2027</td></tr>
  <tr><td>PCB fabrication and assembly</td><td>Q3 2027</td></tr>
  <tr><td>Board validation and testing</td><td>Q4 2027</td></tr>
  <tr><td>First shipments to academia</td><td>Q1 2028</td></tr>
</table>

### 📜 Commercial Terms

<table>
  <tr><th>Term</th><th>Detail</th></tr>
  <tr><td>PCB NRE</td><td>Stencils, artwork, press-fit tooling, programming fixtures</td></tr>
  <tr><td>Assembly NRE</td><td>Pick-and-place programming, test fixtures</td></tr>
  <tr><td>Board BOM</td><td>Chips (internal transfer), PCB, passives, connectors</td></tr>
  <tr><td>Revenue Model</td><td>Direct sale to research orgs; potential grant-funded contracts</td></tr>
</table>

### 🛣️ Submission & Integration Details

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Chip Integration</td><td>Wire-bonded chip-on-board PCBs (wafer.space provides reference designs)</td></tr>
  <tr><td>Bonding Diagram</td><td>Required for wire-bond packaging</td></tr>
  <tr><td>Firmware/Software</td><td>Embedded software development costs fall under IRC Section 174</td></tr>
  <tr><td>Test Firmware</td><td>Board-level test firmware required for validation</td></tr>
</table>

### 📒 Accounting Journal Entries

<table>
  <tr><th>Event</th><th>Debit</th><th>Credit</th><th>Amount</th></tr>
  <tr><td>PCB NRE costs</td><td>R&amp;D – PCB Development (Expense)</td><td>Cash / AP</td><td>NRE amount</td></tr>
  <tr><td>Chip transfer to board inventory</td><td>Inventory – WIP (PDB)</td><td>Inventory – Finished Goods (Chips)</td><td>Internal cost</td></tr>
  <tr><td>PCB and component purchase</td><td>Inventory – WIP (PDB)</td><td>Cash / AP</td><td>BOM cost</td></tr>
  <tr><td>Board assembly complete</td><td>Inventory – Finished Goods (PDB)</td><td>Inventory – WIP (PDB)</td><td>Total board cost</td></tr>
  <tr><td>Board sale to university</td><td>Accounts Receivable</td><td>Revenue – Board Sales</td><td>Sale price</td></tr>
  <tr><td>Cost of goods sold</td><td>COGS – Development Boards</td><td>Inventory – Finished Goods (PDB)</td><td>Board cost</td></tr>
</table>

---

## Consolidated Manifest Summary

<table>
  <tr><th>Chip</th><th>Foundry</th><th>Process</th><th>Slot Cost</th><th>Submission Deadline</th><th>Delivery</th><th>Accounting Account</th></tr>
  <tr><td>RISC-V64 SoC</td><td>wafer.space</td><td>GF180MCU (180nm)</td><td>$2,000–$8,000</td><td>16 Dec 2026</td><td>Q2 2027</td><td>WIP – Foundry (wafer.space)</td></tr>
  <tr><td>GPU</td><td>wafer.space</td><td>GF180MCU (180nm)</td><td>$4,000–$16,000 (2 slots)</td><td>16 Dec 2026</td><td>Q2 2027</td><td>WIP – Foundry (wafer.space)</td></tr>
  <tr><td>PTA</td><td>GF / AMF</td><td>Silicon Photonics</td><td>Quote required</td><td>15th of previous month</td><td>Per AMF schedule</td><td>WIP – Photonics (GF/AMF)</td></tr>
  <tr><td>PDB</td><td>N/A (internal)</td><td>N/A</td><td>N/A</td><td>N/A</td><td>Q1 2028</td><td>Inventory – Finished Goods (PDB)</td></tr>
</table>

---

## Key Accounting Policy Decisions

1. **Capitalization vs. Expensing**: For genuinely new technology (your AI-designed chips), development costs should be **expensed as incurred** under GAAP . For standard tooling and NRE, capitalization may be appropriate .
2. **Multi-Chip Cost Allocation**: Establish a methodology for allocating shared MPW shuttle costs across the RISC-V64 SoC and GPU designs if they share a single shuttle run.
3. **PTA Cost Tracking**: The photonics platform requires a technology agreement and PDK access, which may involve upfront licensing fees that should be capitalized as **Intangible Assets – Photonics PDK License** and amortized over the project life.
4. **Development Board Revenue Recognition**: Under ASC 606, revenue is recognized at a point in time when control transfers. For academic sales, this is typically upon delivery. If boards are sold as part of research grants with ongoing support obligations, revenue may need to be deferred.
5. **Grant Accounting**: If any development board sales are funded by government or institutional grants, establish a **separate fund accounting structure** to track restricted revenue and expenses.

---

# Journal Entry Playbook: AI Chip Development & Development Board Manufacturing

**Entity:** Gridworkz Fabless AI Chip Company  
**Fiscal Year:** Calendar Year  
**Currency:** CA  
**Basis:** CA GAAP

---

## Chart of Accounts Reference

<table>
  <tr><th>Account #</th><th>Account Name</th><th>Type</th></tr>
  <tr><td>1000</td><td>Cash – Operating</td><td>Asset</td></tr>
  <tr><td>1100</td><td>Accounts Receivable</td><td>Asset</td></tr>
  <tr><td>1200</td><td>Prepaid Foundry Costs – wafer.space</td><td>Asset</td></tr>
  <tr><td>1210</td><td>Prepaid Photonics Costs – GF/AMF</td><td>Asset</td></tr>
  <tr><td>1300</td><td>WIP – Foundry (wafer.space)</td><td>Asset</td></tr>
  <tr><td>1310</td><td>WIP – Photonics (GF/AMF)</td><td>Asset</td></tr>
  <tr><td>1320</td><td>WIP – Assembly &amp; Test</td><td>Asset</td></tr>
  <tr><td>1400</td><td>Inventory – Finished Goods (RISC-V64 SoC)</td><td>Asset</td></tr>
  <tr><td>1410</td><td>Inventory – Finished Goods (GPU)</td><td>Asset</td></tr>
  <tr><td>1420</td><td>Inventory – Finished Goods (PTA)</td><td>Asset</td></tr>
  <tr><td>1430</td><td>Inventory – Finished Goods (PDB)</td><td>Asset</td></tr>
  <tr><td>1500</td><td>Intangible Assets – Photonics PDK License</td><td>Asset</td></tr>
  <tr><td>1510</td><td>Accumulated Amortization – PDK License</td><td>Asset (contra)</td></tr>
  <tr><td>2000</td><td>Accounts Payable</td><td>Liability</td></tr>
  <tr><td>2100</td><td>Accrued Liabilities</td><td>Liability</td></tr>
  <tr><td>2200</td><td>Deferred Revenue</td><td>Liability</td></tr>
  <tr><td>3000</td><td>Common Stock</td><td>Equity</td></tr>
  <tr><td>3100</td><td>Retained Earnings</td><td>Equity</td></tr>
  <tr><td>4000</td><td>Revenue – Board Sales</td><td>Revenue</td></tr>
  <tr><td>4100</td><td>Revenue – Grant Revenue</td><td>Revenue</td></tr>
  <tr><td>5000</td><td>COGS – Development Boards</td><td>Expense</td></tr>
  <tr><td>5010</td><td>COGS – Chip Sales</td><td>Expense</td></tr>
  <tr><td>6000</td><td>R&amp;D – Mask &amp; Reticle Costs</td><td>Expense</td></tr>
  <tr><td>6010</td><td>R&amp;D – EDA Software &amp; IP Licensing</td><td>Expense</td></tr>
  <tr><td>6020</td><td>R&amp;D – Design Engineering Labor</td><td>Expense</td></tr>
  <tr><td>6030</td><td>R&amp;D – Prototype &amp; Test Engineering</td><td>Expense</td></tr>
  <tr><td>6040</td><td>R&amp;D – PCB Development</td><td>Expense</td></tr>
  <tr><td>7000</td><td>Amortization – PDK License</td><td>Expense</td></tr>
  <tr><td>8000</td><td>Inventory Write-Down – Obsolete Chips</td><td>Expense</td></tr>
</table>

---

## Section 1: R&D Phase (Design & Pre-Fabrication)

### JE-001: Design Engineering Labor (Monthly)

**Trigger:** Monthly payroll processing for chip designers and AI engineers.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$85,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$85,000</td></tr>
</table>

**Memo:** Monthly salaries for 5 design engineers and 2 AI/ML engineers working on RISC-V64 SoC, GPU, and PTA designs.

---

### JE-002: EDA Software & AI Design Tool Subscriptions (Monthly)

**Trigger:** Monthly cloud-based EDA and AI design tool invoices.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6010 · R&amp;D – EDA Software &amp; IP Licensing</td><td>$12,500</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$12,500</td></tr>
</table>

**Memo:** Monthly subscription for AI-assisted RTL generation, simulation, and verification tools.

---

### JE-003: Photonics PDK License (Upfront)

**Trigger:** Execution of technology agreement and PDK access with GF/AMF.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1500 · Intangible Assets – Photonics PDK License</td><td>$50,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$50,000</td></tr>
</table>

**Memo:** Upfront licensing fee for AMF silicon photonics PDK. Capitalized as an intangible asset and amortized over the estimated useful life of 3 years (36 months).

---

### JE-004: Monthly Amortization of PDK License

**Trigger:** Month-end amortization entry.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>7000 · Amortization – PDK License</td><td>$1,389</td><td></td></tr>
  <tr><td>1510 · Accumulated Amortization – PDK License</td><td></td><td>$1,389</td></tr>
</table>

**Calculation:** $50,000 ÷ 36 months = $1,389/month.

---

### JE-005: Mask & Reticle Costs (MPW Shuttle)

**Trigger:** Invoice received from [wafer.space](https://wafer.space/) for MPW mask and reticle costs associated with the RISC-V64 SoC and GPU designs.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6000 · R&amp;D – Mask &amp; Reticle Costs</td><td>$15,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$15,000</td></tr>
</table>

**Memo:** Mask set cost allocation for GF180MCU Run 3. This is a shared mask cost across all shuttle participants; your portion is $15,000.

**Note:** If the masks have alternative future use, capitalize as an intangible asset. For first-generation prototypes with no alternative use, expense as R&D.

---

### JE-006: Prototype & Test Engineering (Internal Validation)

**Trigger:** Monthly costs for lab equipment, test fixtures, and prototype validation.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6030 · R&amp;D – Prototype &amp; Test Engineering</td><td>$8,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$8,000</td></tr>
</table>

**Memo:** Lab consumables, probe station usage, and test fixture development for first silicon validation.

---

## Section 2: Slot/Order Phase (Prepayments)

### JE-010: RISC-V64 SoC Slot Purchase (Early Bird)

**Trigger:** [wafer.space](https://wafer.space/) invoice for 1× GF180MCU slot for the RISC-V64 SoC.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td>$2,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$2,000</td></tr>
</table>

**Memo:** Early bird slot purchase for GF180MCU Run 3. Design submission deadline: 16 Dec 2026.

---

### JE-011: GPU Slot Purchase (2× Slots for Larger Die)

**Trigger:** [wafer.space](https://wafer.space/) invoice for 2× GF180MCU slots for the GPU design.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td>$4,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$4,000</td></tr>
</table>

**Memo:** Two slots reserved for GPU design requiring reticle stitching. Pricing at early bird rate of $2,000/slot.

---

### JE-012: PTA Photonics Slot Purchase (GF/AMF)

**Trigger:** GF/AMF invoice for photonics MPW slot reservation.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1210 · Prepaid Photonics Costs – GF/AMF</td><td>$35,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$35,000</td></tr>
</table>

**Memo:** Slot reservation for AMF silicon photonics MPW run. Quote-based pricing. GDS submission deadline: 15th of the month preceding the shuttle run.

---

### JE-013: Chip-on-Board Add-On (RISC-V64 SoC & GPU)

**Trigger:** [wafer.space](https://wafer.space/) invoice for chip-on-board packaging add-on.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td>$3,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$3,000</td></tr>
</table>

**Memo:** $1,500 per chip type × 2 chip types (RISC-V64 SoC and GPU) for chip-on-board packaging.

---

## Section 3: Fabrication Phase (WIP Recognition)

### JE-020: RISC-V64 SoC – Design Submitted, Fabrication Begins

**Trigger:** Design submission confirmed by [wafer.space](https://wafer.space/); fabrication commences.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$2,000</td><td></td></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td></td><td>$2,000</td></tr>
</table>

**Memo:** Reclassification of prepaid slot cost to WIP upon design submission. Fabrication begins on GF180MCU Run 3.

---

### JE-021: GPU – Design Submitted, Fabrication Begins

**Trigger:** Design submission confirmed by [wafer.space](https://wafer.space/); fabrication commences.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$4,000</td><td></td></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td></td><td>$4,000</td></tr>
</table>

**Memo:** Reclassification of prepaid slot costs (2 slots) to WIP upon design submission.

---

### JE-022: PTA – GDS Submitted, Photonics Fabrication Begins

**Trigger:** GDS submission confirmed by GF/AMF; photonics fabrication commences.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td>$35,000</td><td></td></tr>
  <tr><td>1210 · Prepaid Photonics Costs – GF/AMF</td><td></td><td>$35,000</td></tr>
</table>

**Memo:** Reclassification of prepaid photonics slot cost to WIP upon GDS submission and DRC waiver.

---

### JE-023: Chip-on-Board Add-On – Incurred

**Trigger:** Chip-on-board packaging add-on cost incurred.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$3,000</td><td></td></tr>
  <tr><td>1200 · Prepaid Foundry Costs – wafer.space</td><td></td><td>$3,000</td></tr>
</table>

**Memo:** Reclassification of prepaid chip-on-board packaging add-on to WIP.

---

### JE-024: Accrual for Fabrication Costs Not Yet Invoiced (Month-End)

**Trigger:** Month-end accrual for fabrication work performed but not yet invoiced by [wafer.space](https://wafer.space/) or GF/AMF.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$5,000</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$5,000</td></tr>
</table>

**Memo:** Accrual for fabrication progress on GF180MCU Run 3 based on milestone completion (e.g., 50% through process). Reverse upon invoice receipt.

---

### JE-025: Reverse Accrual Upon Invoice Receipt

**Trigger:** [wafer.space](https://wafer.space/) invoice received for previously accrued fabrication costs.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2100 · Accrued Liabilities</td><td>$5,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$5,000</td></tr>
</table>

**Memo:** Reversal of month-end accrual and establishment of actual payable upon invoice receipt.

---

## Section 4: Delivery & Inventory Phase

### JE-030: RISC-V64 SoC – Chips Received

**Trigger:** Delivery of 1,000 RISC-V64 SoC dies from [wafer.space](https://wafer.space/).

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td>$2,000</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$2,000</td></tr>
</table>

**Memo:** Capitalization of completed RISC-V64 SoC dies into finished goods inventory. Cost basis: $2.00 per die.

---

### JE-031: GPU – Chips Received

**Trigger:** Delivery of 1,000 GPU dies from [wafer.space](https://wafer.space/).

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td>$4,000</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$4,000</td></tr>
</table>

**Memo:** Capitalization of completed GPU dies into finished goods inventory. Cost basis: $4.00 per die.

---

### JE-032: PTA – Chips Received

**Trigger:** Delivery of PTA photonic chips from GF/AMF.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1420 · Inventory – Finished Goods (PTA)</td><td>$35,000</td><td></td></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td></td><td>$35,000</td></tr>
</table>

**Memo:** Capitalization of completed PTA photonic chips into finished goods inventory.

---

### JE-033: Chip-on-Board Packaging – Allocated

**Trigger:** Allocation of chip-on-board packaging costs to finished goods.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td>$1,500</td><td></td></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td>$1,500</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$3,000</td></tr>
</table>

**Memo:** Allocation of chip-on-board packaging costs. $1,500 per chip type.

---

### JE-034: Inventory Write-Down – Obsolete Chips (Quarterly Assessment)

**Trigger:** Quarterly review identifies chips with no expected future use.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>8000 · Inventory Write-Down – Obsolete Chips</td><td>$500</td><td></td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$500</td></tr>
</table>

**Memo:** Write-down of 250 RISC-V64 SoC dies that failed final validation and have no alternative use. Valued at NRV of $0.

---

## Section 5: Development Board (PDB) Assembly

### JE-040: PCB NRE Costs

**Trigger:** Invoice from PCB vendor for artwork, stencils, and tooling.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6040 · R&amp;D – PCB Development</td><td>$15,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$15,000</td></tr>
</table>

**Memo:** NRE costs for PDB PCB fabrication. These are development costs for a new board design and are expensed as R&D.

---

### JE-041: Chip Transfer to PDB WIP

**Trigger:** Internal transfer of chips from finished goods to PDB assembly WIP.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1320 · WIP – Assembly &amp; Test</td><td>$41,000</td><td></td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$2,000</td></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td></td><td>$4,000</td></tr>
  <tr><td>1420 · Inventory – Finished Goods (PTA)</td><td></td><td>$35,000</td></tr>
</table>

**Memo:** Transfer of 1,000 RISC-V64 SoC dies ($2,000), 1,000 GPU dies ($4,000), and PTA photonic chips ($35,000) into PDB assembly WIP.

---

### JE-042: PCB and Component Purchase

**Trigger:** Invoice from PCB assembly vendor for bare PCBs, passives, connectors, and power management ICs.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1320 · WIP – Assembly &amp; Test</td><td>$28,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$28,000</td></tr>
</table>

**Memo:** Bill of materials for 500 development boards at $56/board. Includes PCB, passives, connectors, and power management.

---

### JE-043: Assembly Labor and Overhead

**Trigger:** Invoice from contract manufacturer for pick-and-place assembly, reflow, and testing.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1320 · WIP – Assembly &amp; Test</td><td>$12,000</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$12,000</td></tr>
</table>

**Memo:** Assembly labor and overhead for 500 development boards at $24/board.

---

### JE-044: Board Assembly Complete – Transfer to Finished Goods

**Trigger:** Completion of 500 PDB development boards.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1430 · Inventory – Finished Goods (PDB)</td><td>$81,000</td><td></td></tr>
  <tr><td>1320 · WIP – Assembly &amp; Test</td><td></td><td>$81,000</td></tr>
</table>

**Memo:** Capitalization of 500 completed PDB development boards. Total cost: $81,000 ($162/board). Cost breakdown: chips $82, PCB $56, assembly $24.

---

## Section 6: Revenue & COGS

### JE-050: Board Sale to University (Direct Sale)

**Trigger:** Shipment of 10 PDB development boards to a research university at $500/board.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable</td><td>$5,000</td><td></td></tr>
  <tr><td>4000 · Revenue – Board Sales</td><td></td><td>$5,000</td></tr>
</table>

**Memo:** Sale of 10 PDB development boards to university research lab. Revenue recognized upon shipment (control transferred).

---

### JE-051: Cost of Goods Sold – Board Sale

**Trigger:** Recognition of COGS for 10 boards sold.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>5000 · COGS – Development Boards</td><td>$1,620</td><td></td></tr>
  <tr><td>1430 · Inventory – Finished Goods (PDB)</td><td></td><td>$1,620</td></tr>
</table>

**Memo:** COGS for 10 boards at $162/board.

---

### JE-052: Grant-Funded Board Sale (Deferred Revenue)

**Trigger:** University purchases 20 boards using grant funding with a requirement for 12 months of technical support.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable</td><td>$10,000</td><td></td></tr>
  <tr><td>2200 · Deferred Revenue</td><td></td><td>$10,000</td></tr>
</table>

**Memo:** Grant-funded sale of 20 boards at $500/board. Revenue deferred due to ongoing performance obligation (technical support).

---

### JE-053: Revenue Recognition – Grant Support Period (Monthly)

**Trigger:** Monthly recognition of deferred revenue over 12-month support period.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2200 · Deferred Revenue</td><td>$833</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td></td><td>$833</td></tr>
</table>

**Memo:** Monthly recognition of deferred revenue. $10,000 ÷ 12 months = $833/month.

---

### JE-054: Cost of Goods Sold – Grant-Funded Board Sale

**Trigger:** Recognition of COGS for 20 boards sold under grant.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>5000 · COGS – Development Boards</td><td>$3,240</td><td></td></tr>
  <tr><td>1430 · Inventory – Finished Goods (PDB)</td><td></td><td>$3,240</td></tr>
</table>

**Memo:** COGS for 20 boards at $162/board.

---

### JE-055: Chip Sale to Research Organization (Direct)

**Trigger:** Sale of 100 RISC-V64 SoC dies to a research organization at $50/die.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable</td><td>$5,000</td><td></td></tr>
  <tr><td>5010 · COGS – Chip Sales</td><td></td><td>$200</td></tr>
  <tr><td>1430 · Inventory – Finished Goods (PDB)</td><td></td><td></td></tr>
  <tr><td>4000 · Revenue – Board Sales</td><td></td><td>$5,000</td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$200</td></tr>
</table>

**Memo:** Sale of 100 RISC-V64 SoC dies. Revenue recognized upon shipment. COGS at $2/die.

**Corrected Entry:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable</td><td>$5,000</td><td></td></tr>
  <tr><td>4000 · Revenue – Board Sales</td><td></td><td>$5,000</td></tr>
  <tr><td>5010 · COGS – Chip Sales</td><td>$200</td><td></td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$200</td></tr>
</table>

---

## Section 7: Period-End Adjustments

### JE-060: Accrued Foundry Costs (Month-End)

**Trigger:** Month-end accrual for fabrication progress not yet invoiced.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$3,500</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$3,500</td></tr>
</table>

**Memo:** Accrual for GF180MCU Run 3 fabrication progress based on milestone completion (e.g., 70% through process). Reverse upon invoice receipt.

---

### JE-061: Accrued Photonics Costs (Month-End)

**Trigger:** Month-end accrual for photonics fabrication progress not yet invoiced.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td>$8,000</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$8,000</td></tr>
</table>

**Memo:** Accrual for AMF photonics MPW run progress. Reverse upon invoice receipt.

---

### JE-062: Inventory Obsolescence Reserve (Quarterly)

**Trigger:** Quarterly assessment of inventory for excess and obsolete chips.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>8000 · Inventory Write-Down – Obsolete Chips</td><td>$2,500</td><td></td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$1,000</td></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td></td><td>$1,500</td></tr>
</table>

**Memo:** Write-down of slow-moving RISC-V64 SoC and GPU inventory. Chips older than 18 months with no expected sales are written down to NRV.

---

### JE-063: Depreciation of Lab Equipment (Monthly)

**Trigger:** Monthly depreciation of probe stations, oscilloscopes, and test equipment.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6030 · R&amp;D – Prototype &amp; Test Engineering</td><td>$2,000</td><td></td></tr>
  <tr><td>1510 · Accumulated Depreciation – Lab Equipment</td><td></td><td>$2,000</td></tr>
</table>

**Memo:** Monthly depreciation of lab equipment used for chip validation.

---

### JE-064: Accrued Vacation and Payroll Taxes (Month-End)

**Trigger:** Month-end accrual for employee vacation and payroll taxes.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$12,000</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$12,000</td></tr>
</table>

**Memo:** Accrual for unpaid vacation time and employer payroll taxes.

---

## Section 8: Grant Accounting (If Applicable)

### JE-070: Grant Receipt – Restricted Funds

**Trigger:** Receipt of government research grant for development board project.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1000 · Cash – Operating</td><td>$250,000</td><td></td></tr>
  <tr><td>2200 · Deferred Revenue</td><td></td><td>$250,000</td></tr>
</table>

**Memo:** Receipt of restricted grant funds for AI chip development board research. Funds are restricted to specific project deliverables.

---

### JE-071: Grant Expenditure – R&D Costs

**Trigger:** Monthly recognition of grant-funded R&D expenses.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$25,000</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$25,000</td></tr>
</table>

**Memo:** Grant-funded design engineering labor for the reporting period.

---

### JE-072: Grant Revenue Recognition

**Trigger:** Recognition of grant revenue as allowable costs are incurred.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2200 · Deferred Revenue</td><td>$25,000</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td></td><td>$25,000</td></tr>
</table>

**Memo:** Recognition of grant revenue matching allowable costs incurred during the period.

---

## Section 9: Year-End Close Entries

### JE-080: Close R&D Accounts to Retained Earnings

**Trigger:** Year-end closing entry.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>3100 · Retained Earnings</td><td>$XXX,XXX</td><td></td></tr>
  <tr><td>6000 · R&amp;D – Mask &amp; Reticle Costs</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>6010 · R&amp;D – EDA Software &amp; IP Licensing</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>6030 · R&amp;D – Prototype &amp; Test Engineering</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>6040 · R&amp;D – PCB Development</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>7000 · Amortization – PDK License</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>8000 · Inventory Write-Down – Obsolete Chips</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>5000 · COGS – Development Boards</td><td></td><td>$XX,XXX</td></tr>
  <tr><td>5010 · COGS – Chip Sales</td><td></td><td>$XX,XXX</td></tr>
</table>

**Memo:** Close all expense and COGS accounts to Retained Earnings.

---

### JE-081: Close Revenue Accounts to Retained Earnings

**Trigger:** Year-end closing entry.

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>4000 · Revenue – Board Sales</td><td>$XXX,XXX</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td>$XX,XXX</td><td></td></tr>
  <tr><td>3100 · Retained Earnings</td><td></td><td>$XXX,XXX</td></tr>
</table>

**Memo:** Close all revenue accounts to Retained Earnings.

---

## Summary: Journal Entry Flow by Project Stage

<table>
  <tr><th>Stage</th><th>JE #</th><th>Key Accounts</th><th>Trigger</th></tr>
  <tr><td>R&amp;D</td><td>JE-001 to JE-006</td><td>6010, 6020, 6030, 1500</td><td>Monthly payroll, subscriptions, PDK license</td></tr>
  <tr><td>Slot/Order</td><td>JE-010 to JE-013</td><td>1200, 1210</td><td>wafer.space/GF invoice</td></tr>
  <tr><td>Fabrication</td><td>JE-020 to JE-025</td><td>1300, 1310</td><td>Design submission, month-end accrual</td></tr>
  <tr><td>Delivery</td><td>JE-030 to JE-034</td><td>1400, 1410, 1420</td><td>Chip delivery</td></tr>
  <tr><td>PDB Assembly</td><td>JE-040 to JE-044</td><td>1320, 1430</td><td>PCB NRE, assembly completion</td></tr>
  <tr><td>Revenue</td><td>JE-050 to JE-055</td><td>4000, 4100, 5000, 5010</td><td>Board/chip shipment</td></tr>
  <tr><td>Period-End</td><td>JE-060 to JE-064</td><td>2100, 8000, 1510</td><td>Month-end/quarter-end</td></tr>
  <tr><td>Grant</td><td>JE-070 to JE-072</td><td>2200, 4100</td><td>Grant receipt/expenditure</td></tr>
  <tr><td>Year-End</td><td>JE-080 to JE-081</td><td>3100</td><td>Fiscal year close</td></tr>
</table>

---

## Key Controls & Reconciliation Procedures

1. **Three-Way Match**: Match purchase order, receiving report, and invoice before recording any foundry or assembly payable.
2. **WIP Reconciliation**: Reconcile WIP – Foundry and WIP – Photonics accounts monthly against [wafer.space](https://wafer.space/) and GF/AMF statements.
3. **Inventory Count**: Perform quarterly physical inventory counts of chips and development boards. Reconcile to perpetual records.
4. **Grant Compliance**: Track restricted grant funds separately. Maintain documentation of allowable costs for audit purposes.
5. **Revenue Cut-Off**: Establish clear shipping terms with universities. Recognize revenue only when control transfers (typically FOB shipping point or destination, per the purchase order).
6. **Obsolescence Review**: Conduct quarterly reviews of chip and board inventory. Document assumptions for NRV calculations.
7. **Accrual Reversal**: Establish a policy to reverse all month-end accruals on the first day of the following month to avoid double-counting.

---

# Variance Analysis Playbook: AI Chip Development & Development Board Manufacturing

**Entity:** Gridworkz Fabless AI Chip Company  
**Methodology:** Standard Costing with Full Variance Decomposition  
**Reporting Cadence:** Monthly close; quarterly deep-dive

## Section 1: Standard Cost Card Design

Before variance analysis can begin, you need standard costs established for each cost element. Most semiconductor companies use the Standard Costing method, and variances from these standards are recorded and investigated as costs move through the system.

### 1.1 Standard Cost Card – RISC-V64 SoC ([wafer.space](https://wafer.space/) / GF180MCU)

<table>
  <tr><th>Cost Element</th><th>Standard Quantity</th><th>Standard Price</th><th>Standard Cost per Die</th></tr>
  <tr><td>Foundry fabrication (1 slot)</td><td>1 slot / 1,000 expected dies</td><td>$2,000/slot</td><td>$2.00</td></tr>
  <tr><td>Expected yield</td><td>95% (standard)</td><td>—</td><td>—</td></tr>
  <tr><td>Yield-adjusted foundry cost</td><td>1 slot / 950 good dies</td><td>$2,000/slot</td><td>$2.11</td></tr>
  <tr><td>Chip-on-board packaging</td><td>1 unit</td><td>$1.50/die</td><td>$1.50</td></tr>
  <tr><td>Total standard cost per good die</td><td></td><td></td><td>$3.61</td></tr>
</table>

### 1.2 Standard Cost Card – GPU ([wafer.space](https://wafer.space/) / GF180MCU, 2 Slots)

<table>
  <tr><th>Cost Element</th><th>Standard Quantity</th><th>Standard Price</th><th>Standard Cost per Die</th></tr>
  <tr><td>Foundry fabrication (2 slots)</td><td>2 slots / 2,000 expected dies</td><td>$2,000/slot</td><td>$2.00</td></tr>
  <tr><td>Expected yield</td><td>90% (standard, larger die)</td><td>—</td><td>—</td></tr>
  <tr><td>Yield-adjusted foundry cost</td><td>2 slots / 1,800 good dies</td><td>$4,000</td><td>$2.22</td></tr>
  <tr><td>Reticle stitching premium</td><td>1 unit</td><td>$0.50/die</td><td>$0.50</td></tr>
  <tr><td>Chip-on-board packaging</td><td>1 unit</td><td>$1.50/die</td><td>$1.50</td></tr>
  <tr><td>Total standard cost per good die</td><td></td><td></td><td>$4.22</td></tr>
</table>

### 1.3 Standard Cost Card – PTA (GF/AMF Photonics)

<table>
  <tr><th>Cost Element</th><th>Standard Quantity</th><th>Standard Price</th><th>Standard Cost per Chip</th></tr>
  <tr><td>Photonics fabrication (MPW slot)</td><td>1 slot / 500 expected chips</td><td>$35,000/slot</td><td>$70.00</td></tr>
  <tr><td>Expected yield</td><td>85% (standard, photonics)</td><td>—</td><td>—</td></tr>
  <tr><td>Yield-adjusted fabrication cost</td><td>1 slot / 425 good chips</td><td>$35,000</td><td>$82.35</td></tr>
  <tr><td>Dicing and cleaving</td><td>1 unit</td><td>$2.00/chip</td><td>$2.00</td></tr>
  <tr><td>Total standard cost per good chip</td><td></td><td></td><td>$84.35</td></tr>
</table>

### 1.4 Standard Cost Card – PDB Development Board

<table>
  <tr><th>Cost Element</th><th>Standard Quantity</th><th>Standard Price</th><th>Standard Cost per Board</th></tr>
  <tr><td>RISC-V64 SoC die</td><td>1 die</td><td>$3.61/die</td><td>$3.61</td></tr>
  <tr><td>GPU die</td><td>1 die</td><td>$4.22/die</td><td>$4.22</td></tr>
  <tr><td>PTA photonic chip</td><td>1 chip</td><td>$84.35/chip</td><td>$84.35</td></tr>
  <tr><td>Bare PCB</td><td>1 board</td><td>$18.00/board</td><td>$18.00</td></tr>
  <tr><td>Passive components</td><td>1 set</td><td>$12.00/board</td><td>$12.00</td></tr>
  <tr><td>Connectors &amp; power mgmt</td><td>1 set</td><td>$26.00/board</td><td>$26.00</td></tr>
  <tr><td>Assembly labor</td><td>1 board</td><td>$24.00/board</td><td>$24.00</td></tr>
  <tr><td>Total standard cost per board</td><td></td><td></td><td>$172.18</td></tr>
</table>

## Section 2: Variance Taxonomy for Your Project

Tensoft SemiOps calculates five variances at the time of receipt and one at the time of invoicing. For your AI chip and development board operation, the following variance taxonomy applies:

<table>
  <tr><th>Variance Type</th><th>Applies To</th><th>Responsibility Center</th></tr>
  <tr><td>Purchase Price Variance (PPV)</td><td>Foundry slots, PDK licenses, PCB components</td><td>Procurement</td></tr>
  <tr><td>Yield Variance</td><td>All three chips (RISC-V64, GPU, PTA)</td><td>Foundry Operations</td></tr>
  <tr><td>Process Variance</td><td>Photonics (PTA) and GPU (stitching)</td><td>Engineering</td></tr>
  <tr><td>Labor Rate Variance</td><td>Design engineers, test engineers</td><td>HR / Engineering Management</td></tr>
  <tr><td>Labor Efficiency Variance</td><td>Design cycle time, test throughput</td><td>Engineering Management</td></tr>
  <tr><td>R&amp;D Budget Variance</td><td>All R&amp;D cost centers</td><td>CFO / CTO</td></tr>
  <tr><td>BOM Variance</td><td>PDB development board</td><td>Supply Chain</td></tr>
  <tr><td>Overhead Volume Variance</td><td>Lab equipment, shared facilities</td><td>Operations</td></tr>
</table>

## Section 3: Material and Purchase Price Variance (PPV) Analysis

### 3.1 RISC-V64 SoC — Foundry Slot PPV

**Scenario:** You budgeted $2,000/slot (early bird) but [wafer.space](https://wafer.space/) invoiced $8,000/slot (standard pricing) because you missed the early-bird deadline. The GPU required 2 slots at the same pricing.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>RISC-V64 SoC slot price</td><td>$2,000</td><td>$8,000</td><td>$6,000 U</td></tr>
  <tr><td>GPU slot price (×2)</td><td>$4,000</td><td>$16,000</td><td>$12,000 U</td></tr>
  <tr><td>Total Foundry PPV</td><td>$6,000</td><td>$24,000</td><td>$18,000 U</td></tr>
</table>

**Journal Entry — PPV Recognition:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$24,000</td><td></td></tr>
  <tr><td>5100 · PPV – Foundry Slot Price</td><td>$18,000 U</td><td></td></tr>
  <tr><td>1200 · Prepaid Foundry Costs</td><td></td><td>$6,000</td></tr>
</table>

**Root Cause Analysis:**

- **Primary driver:** Missed early-bird deadline of 09 Dec 2026.
- **Secondary driver:** GPU design required 2 slots (reticle stitching), doubling exposure.
- **Corrective action:** Implement design freeze milestone 4 weeks before slot purchase deadline. Assign a dedicated program manager for foundry engagement.

### 3.2 PTA — Photonics MPW Slot PPV

**Scenario:** You budgeted $35,000 for the AMF photonics MPW slot based on the quote, but the final invoice came in at $42,000 due to additional DRC iterations beyond the standard 3.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>PTA photonics slot</td><td>$35,000</td><td>$42,000</td><td>$7,000 U</td></tr>
</table>

**Journal Entry — PPV Recognition:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td>$42,000</td><td></td></tr>
  <tr><td>5110 · PPV – Photonics Slot Price</td><td>$7,000 U</td><td></td></tr>
  <tr><td>1210 · Prepaid Photonics Costs</td><td></td><td>$35,000</td></tr>
</table>

**Root Cause Analysis:**

- **Primary driver:** DRC violations required 5 iterations (vs. standard 3), incurring $3,500 per additional iteration.
- **Root cause:** AI-generated photonic layout did not fully account for AMF-specific DRC rules (waveguide bend radius, minimum separation).
- **Corrective action:** Integrate AMF DRC rule deck into AI design tool verification loop. Pre-validate photonic layouts against foundry-specific rules before submission.

### 3.3 MPW Cost Allocation — Die Size and Slot Efficiency

MPW pricing is area-based, meaning large die designs consume more of the shared reticle and incur proportionally higher costs. Your GPU design, requiring reticle stitching across 2 slots, illustrates this. The sensitivity of MPW production cost to die area means that removing a large-area project from a run would actually decrease the cost shared by remaining projects.

**Analysis:**

<table>
  <tr><th>Chip</th><th>Die Area</th><th>Slot Fraction</th><th>Standard Cost Allocation</th><th>Actual Cost Allocation</th></tr>
  <tr><td>RISC-V64 SoC</td><td>19.67 mm²</td><td>1.0 slot</td><td>$2,000</td><td>$8,000</td></tr>
  <tr><td>GPU</td><td>39.34 mm² (stitched)</td><td>2.0 slots</td><td>$4,000</td><td>$16,000</td></tr>
  <tr><td>Combined</td><td></td><td>3.0 slots</td><td>$6,000</td><td>$24,000</td></tr>
</table>

**Key insight:** If you had combined the RISC-V64 SoC and GPU designs onto a single optimized reticle with efficient area packing, you may have fit both into 2.5 slots instead of 3.0, saving $4,000. However, the larger GPU die area increases the risk of yield loss, which may offset the slot savings.

## Section 4: Yield Variance Analysis

Yield is the most critical variance driver in semiconductor manufacturing. A 5% yield drop can destroy 20–40% of EBITDA because every wafer carries full fixed cost regardless of output.

### 4.1 RISC-V64 SoC — Yield Variance

**Scenario:** Standard yield is 95% (950 good dies from 1,000). Actual yield was 88% (880 good dies from 1,000), meaning 70 dies failed final electrical test.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>Expected good dies</td><td>950</td><td>880</td><td>70 dies U</td></tr>
  <tr><td>Cost per good die</td><td>$2.11</td><td>$2.27</td><td>$0.16 U</td></tr>
  <tr><td>Total yield variance</td><td>—</td><td>—</td><td>$140 U</td></tr>
</table>

**Calculation:**

- Standard cost per good die = $2,000 ÷ 950 = $2.11
- Actual cost per good die = $2,000 ÷ 880 = $2.27
- Yield variance = (950 − 880) × $2.11 = **$148 U** (approximately $140 due to rounding)

**Journal Entry — Yield Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td>$2,000</td><td></td></tr>
  <tr><td>5120 · Yield Variance – RISC-V64 SoC</td><td>$148 U</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$2,000</td></tr>
</table>

**Note:** The yield variance is absorbed into COGS when the chips are sold. The inventory account carries the standard cost, and the variance remains in a separate variance account until period-end close.

**Root Cause Analysis:**

- **Primary driver:** 42 dies failed at the NPU functional test stage; 28 dies failed at scan chain test.
- **Root cause:** AI-generated RTL for the NPU clock domain crossing introduced a metastability issue that only manifested at 180nm process corners.
- **Corrective action:** Enhance AI verification with formal CDC (clock domain crossing) checks. Add corner-case simulation for 180nm process variations.

### 4.2 GPU — Yield Variance with Reticle Stitching

**Scenario:** Standard yield is 90% (1,800 good dies from 2,000). Actual yield was 78% (1,560 good dies from 2,000), meaning 440 dies failed. The yield loss is concentrated at the stitch boundary.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>Expected good dies</td><td>1,800</td><td>1,560</td><td>240 dies U</td></tr>
  <tr><td>Cost per good die</td><td>$2.22</td><td>$2.56</td><td>$0.34 U</td></tr>
  <tr><td>Total yield variance</td><td>—</td><td>—</td><td>$533 U</td></tr>
</table>

**Journal Entry — Yield Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td>$4,000</td><td></td></tr>
  <tr><td>5130 · Yield Variance – GPU</td><td>$533 U</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$4,000</td></tr>
</table>

**Root Cause Analysis:**

- **Primary driver:** 180 dies failed due to stitch boundary misalignment (overlay error > 50nm).
- **Secondary driver:** 60 dies failed due to GPU memory controller timing violations.
- **Root cause:** Reticle stitching requires 24 stitch boundaries per layer, with significant risk of yield loss. The yield and cost are proportional to the number of masks and processing steps.
- **Corrective action:** Add stitch-aware layout constraints to AI place-and-route engine. Collaborate with [wafer.space](https://wafer.space/) on stitch optimization for the GPU design in Run 4.

### 4.3 PTA — Photonics Yield Variance

**Scenario:** Standard yield is 85% (425 good chips from 500). Actual yield was 72% (360 good chips from 500), meaning 140 chips failed. Photonic yield loss is concentrated at the grating coupler and waveguide bend regions.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>Expected good chips</td><td>425</td><td>360</td><td>65 chips U</td></tr>
  <tr><td>Cost per good chip</td><td>$82.35</td><td>$97.22</td><td>$14.87 U</td></tr>
  <tr><td>Total yield variance</td><td>—</td><td>—</td><td>$5,353 U</td></tr>
</table>

**Journal Entry — Yield Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1420 · Inventory – Finished Goods (PTA)</td><td>$35,000</td><td></td></tr>
  <tr><td>5140 · Yield Variance – PTA</td><td>$5,353 U</td><td></td></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td></td><td>$35,000</td></tr>
</table>

**Root Cause Analysis:**

- **Primary driver:** 85 chips failed due to excessive insertion loss at grating couplers (> 3dB).
- **Secondary driver:** 55 chips failed due to waveguide sidewall roughness causing scattering loss.
- **Root cause:** AI-generated photonic layout did not optimize for AMF's specific silicon nitride waveguide process, which has different sidewall roughness characteristics than the design tool's default model.
- **Corrective action:** Recalibrate AI photonic design model with AMF process-specific loss parameters. Run a design-of-experiments (DOE) shuttle with AMF to characterize waveguide loss at different widths and bend radii.

### 4.4 Cost of Yield (COY) Dashboard

The Cost of Yield is a measure of the additional dollars debited to production expenses when aggregate productivity falls below the business plan. IBM Microelectronics has calculated COY since 1995 and uses it to validate resource allocations and identify products with the largest yield variances.

<table>
  <tr><th>Chip</th><th>Standard Yield</th><th>Actual Yield</th><th>Yield Gap</th><th>COY Impact</th></tr>
  <tr><td>RISC-V64 SoC</td><td>95%</td><td>88%</td><td>−7 pp</td><td>$148 U</td></tr>
  <tr><td>GPU</td><td>90%</td><td>78%</td><td>−12 pp</td><td>$533 U</td></tr>
  <tr><td>PTA</td><td>85%</td><td>72%</td><td>−13 pp</td><td>$5,353 U</td></tr>
  <tr><td>Total</td><td></td><td></td><td></td><td>$6,034 U</td></tr>
</table>

**Management action:** The PTA photonics yield gap is the largest single variance driver in dollar terms. A yield improvement task force should be formed with a specific focus on grating coupler design and AMF process characterization.

## Section 5: Labor and Efficiency Variance Analysis

### 5.1 Design Engineering Labor Rate Variance

**Scenario:** You budgeted 5 design engineers at an average fully loaded rate of $170,000/year ($14,167/month). Due to a competitive hiring market for AI chip designers, you actually hired at an average rate of $195,000/year ($16,250/month). You also used 2 contract engineers at $22,000/month to accelerate the schedule.

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>FTE design engineers</td><td>5</td><td>5</td><td>—</td></tr>
  <tr><td>Contract engineers</td><td>0</td><td>2</td><td>+2</td></tr>
  <tr><td>Monthly labor cost</td><td>$70,835</td><td>$125,250</td><td>$54,415 U</td></tr>
  <tr><td>Labor rate variance</td><td>—</td><td>—</td><td>$10,415 U</td></tr>
  <tr><td>Labor efficiency variance</td><td>—</td><td>—</td><td>$44,000 U</td></tr>
</table>

**Calculation:**

- Standard labor cost = 5 × $14,167 = $70,835
- Rate variance = 5 × ($16,250 − $14,167) = **$10,415 U**
- Efficiency variance = 2 contract engineers × $22,000 = **$44,000 U**

**Journal Entry — Labor Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$125,250</td><td></td></tr>
  <tr><td>5150 · Labor Rate Variance</td><td>$10,415 U</td><td></td></tr>
  <tr><td>5160 · Labor Efficiency Variance</td><td>$44,000 U</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$125,250</td></tr>
</table>

**Root Cause Analysis:**

- **Rate variance:** AI chip design talent commands a 15% premium over standard ASIC designers. The standard rate was set based on 2025 market data and needs to be updated for 2027.
- **Efficiency variance:** The contract engineers were brought on to accelerate the GPU design (which was behind schedule due to reticle stitching complexity). This is an unfavorable efficiency variance but a necessary investment to meet the Q2 2027 chip delivery deadline.
- **Corrective action:** Revise standard labor rates annually. Budget for contract engineering capacity in the GPU project plan from the start.

### 5.2 R&D Budget Variance Dashboard

<table>
  <tr><th>R&amp;D Category</th><th>Budget</th><th>Actual</th><th>Variance</th><th>% Variance</th></tr>
  <tr><td>Design engineering labor</td><td>$850,000</td><td>$1,503,000</td><td>$653,000 U</td><td>+76.8%</td></tr>
  <tr><td>EDA software &amp; IP licensing</td><td>$150,000</td><td>$175,000</td><td>$25,000 U</td><td>+16.7%</td></tr>
  <tr><td>Mask &amp; reticle costs</td><td>$15,000</td><td>$22,000</td><td>$7,000 U</td><td>+46.7%</td></tr>
  <tr><td>Prototype &amp; test engineering</td><td>$96,000</td><td>$138,000</td><td>$42,000 U</td><td>+43.8%</td></tr>
  <tr><td>PCB development</td><td>$15,000</td><td>$28,000</td><td>$13,000 U</td><td>+86.7%</td></tr>
  <tr><td>PDK license amortization</td><td>$16,667</td><td>$16,667</td><td>—</td><td>—</td></tr>
  <tr><td>Total R&amp;D</td><td>$1,142,667</td><td>$1,882,667</td><td>$740,000 U</td><td>+64.7%</td></tr>
</table>

**Key insight:** The R&D budget overrun is driven primarily by labor costs (76.8% over budget). This is consistent with industry patterns where fabless companies ramping new AI chip designs show significant R&D spending increases. Rebellion, a South Korean AI chip fabless company, reported a 46.6% increase in R&D expenses in 2025 as it ramped new chip designs.

## Section 6: Development Board BOM Variance Analysis

### 6.1 Component-Level BOM Variance

<table>
  <tr><th>Component</th><th>Standard Cost</th><th>Actual Cost</th><th>Variance</th><th>Root Cause</th></tr>
  <tr><td>RISC-V64 SoC die</td><td>$3.61</td><td>$3.61</td><td>—</td><td>Internal transfer at standard</td></tr>
  <tr><td>GPU die</td><td>$4.22</td><td>$4.22</td><td>—</td><td>Internal transfer at standard</td></tr>
  <tr><td>PTA photonic chip</td><td>$84.35</td><td>$97.22</td><td>$12.87 U</td><td>Yield variance absorbed</td></tr>
  <tr><td>Bare PCB</td><td>$18.00</td><td>$21.50</td><td>$3.50 U</td><td>4-layer to 6-layer stackup upgrade for impedance control</td></tr>
  <tr><td>Passive components</td><td>$12.00</td><td>$14.75</td><td>$2.75 U</td><td>0402 to 0201 transition for space constraints</td></tr>
  <tr><td>Connectors &amp; power mgmt</td><td>$26.00</td><td>$31.00</td><td>$5.00 U</td><td>USB-C PD controller price increase</td></tr>
  <tr><td>Assembly labor</td><td>$24.00</td><td>$28.50</td><td>$4.50 U</td><td>Additional rework for photonic chip alignment</td></tr>
  <tr><td>Total BOM</td><td>$172.18</td><td>$200.80</td><td>$28.62 U</td><td></td></tr>
</table>

### 6.2 BOM Variance Journal Entry

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1320 · WIP – Assembly &amp; Test</td><td>$200.80</td><td></td></tr>
  <tr><td>5170 · BOM Variance – PDB</td><td>$28.62 U</td><td></td></tr>
  <tr><td>2000 · Accounts Payable</td><td></td><td>$172.18</td></tr>
</table>

**Note:** The PTA photonic chip cost variance ($12.87) is the largest single component. This flows directly from the photonics yield variance analyzed in Section 4.3. The PCB stackup upgrade was necessary to support the high-speed differential pairs required for the photonic tensor accelerator's optical I/O interface.

### 6.3 Development Board Gross Margin Analysis

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th></tr>
  <tr><td>Selling price per board</td><td>$500.00</td><td>$500.00</td></tr>
  <tr><td>Standard cost per board</td><td>$172.18</td><td>$200.80</td></tr>
  <tr><td>Gross margin per board</td><td>$327.82</td><td>$299.20</td></tr>
  <tr><td>Gross margin %</td><td>65.6%</td><td>59.8%</td></tr>
</table>

**Margin impact:** The $28.62 BOM variance reduces gross margin by 5.8 percentage points. At 500 boards sold, the total margin erosion is **$14,310**. This is material for a research-focused product where pricing is constrained by academic budgets.

## Section 7: Manufacturing Overhead Variance Analysis

### 7.1 Overhead Volume Variance

The overhead volume variance is the difference between actual and budgeted wafer finishes multiplied by the overhead burden rate.

**Scenario:** You budgeted for 3 MPW runs (1 RISC-V64, 1 GPU, 1 PTA) in the fiscal year. The overhead burden rate is $15,000 per run. Actual runs completed: 2 (the PTA photonics run was deferred due to DRC issues).

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>MPW runs</td><td>3</td><td>2</td><td>1 U</td></tr>
  <tr><td>Overhead burden rate</td><td>$15,000/run</td><td>$15,000/run</td><td>—</td></tr>
  <tr><td>Overhead volume variance</td><td>—</td><td>—</td><td>$15,000 U</td></tr>
</table>

**Journal Entry — Overhead Volume Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>5180 · Overhead Volume Variance</td><td>$15,000 U</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$15,000</td></tr>
</table>

**Root Cause:** The PTA photonics run was deferred from Q3 to Q4 due to additional DRC iterations required by AMF. The overhead (lab equipment depreciation, facility costs, shared engineering support) was still incurred but not absorbed into production.

### 7.2 Overhead Spending Variance

<table>
  <tr><th>Overhead Item</th><th>Budget</th><th>Actual</th><th>Variance</th></tr>
  <tr><td>Lab equipment depreciation</td><td>$24,000</td><td>$24,000</td><td>—</td></tr>
  <tr><td>Facility costs (shared lab)</td><td>$18,000</td><td>$21,500</td><td>$3,500 U</td></tr>
  <tr><td>Indirect engineering support</td><td>$36,000</td><td>$42,000</td><td>$6,000 U</td></tr>
  <tr><td>Test fixture maintenance</td><td>$9,000</td><td>$11,200</td><td>$2,200 U</td></tr>
  <tr><td>Total overhead</td><td>$87,000</td><td>$98,700</td><td>$11,700 U</td></tr>
</table>

**Journal Entry — Overhead Spending Variance:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6030 · R&amp;D – Prototype &amp; Test Engineering</td><td>$98,700</td><td></td></tr>
  <tr><td>5190 · Overhead Spending Variance</td><td>$11,700 U</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$98,700</td></tr>
</table>

## Section 8: Month-End Variance Analysis Workflow

The month-end process typically starts by looking at the change in inventory value between two points in time. The Inventory Change Summary report shows inventory balances, the change between the two values, and the explanation of the change.

### 8.1 Monthly Close Checklist

<table>
  <tr><th>Step</th><th>Activity</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td>Pull Inventory Change Summary (WIP, FG by product)</td><td>Accounting</td><td>Day 1</td></tr>
  <tr><td>2</td><td>Calculate PPV on all foundry invoices received</td><td>Procurement</td><td>Day 2</td></tr>
  <tr><td>3</td><td>Calculate yield variance for each chip (based on received die counts)</td><td>Foundry Ops</td><td>Day 2</td></tr>
  <tr><td>4</td><td>Calculate labor rate and efficiency variances</td><td>HR / Engineering</td><td>Day 3</td></tr>
  <tr><td>5</td><td>Calculate BOM variance on PDB assembly</td><td>Supply Chain</td><td>Day 3</td></tr>
  <tr><td>6</td><td>Calculate overhead volume and spending variances</td><td>Operations</td><td>Day 4</td></tr>
  <tr><td>7</td><td>Prepare R&amp;D budget variance report by category</td><td>FP&amp;A</td><td>Day 4</td></tr>
  <tr><td>8</td><td>Review variance report with CFO and CTO</td><td>Finance</td><td>Day 5</td></tr>
  <tr><td>9</td><td>Post period-end variance journal entries</td><td>Accounting</td><td>Day 5</td></tr>
  <tr><td>10</td><td>Distribute variance action items to responsibility centers</td><td>Finance</td><td>Day 6</td></tr>
</table>

### 8.2 Variance Investigation Threshold

<table>
  <tr><th>Variance Type</th><th>Threshold for Investigation</th><th>Escalation</th></tr>
  <tr><td>PPV</td><td>&gt; $5,000 or &gt; 10%</td><td>Procurement Manager → CFO</td></tr>
  <tr><td>Yield</td><td>&gt; 3 percentage points</td><td>Foundry Ops → CTO</td></tr>
  <tr><td>Labor Rate</td><td>&gt; 5%</td><td>HR → CEO</td></tr>
  <tr><td>Labor Efficiency</td><td>&gt; $20,000</td><td>Engineering Manager → CTO</td></tr>
  <tr><td>BOM</td><td>&gt; $10 per board</td><td>Supply Chain → COO</td></tr>
  <tr><td>R&amp;D Budget</td><td>&gt; 15% in any category</td><td>FP&amp;A → CFO / CTO</td></tr>
  <tr><td>Overhead Volume</td><td>&gt; $10,000</td><td>Operations → CFO</td></tr>
</table>

## Section 9: Variance Reporting Template

### 9.1 Executive Summary (Monthly)

**Period:** [Month/Year]  
**Prepared by:** [Name]  
**Date:** [Date]

**Summary of Material Variances:**

<table>
  <tr><th>#</th><th>Variance</th><th>Amount</th><th>F/U</th><th>Primary Root Cause</th><th>Action Owner</th><th>Target Resolution</th></tr>
  <tr><td>1</td><td>Foundry slot PPV</td><td>$18,000</td><td>U</td><td>Missed early-bird deadline; GPU 2-slot requirement</td><td>Program Mgmt</td><td>Next slot purchase</td></tr>
  <tr><td>2</td><td>PTA photonics yield</td><td>$5,353</td><td>U</td><td>Grating coupler insertion loss; AMF process model mismatch</td><td>Photonics Eng</td><td>Q1 2028 DOE run</td></tr>
  <tr><td>3</td><td>Design engineering labor</td><td>$54,415</td><td>U</td><td>AI talent premium; contract engineers for GPU acceleration</td><td>HR / Engineering</td><td>Standard rate revision</td></tr>
  <tr><td>4</td><td>GPU yield (stitching)</td><td>$533</td><td>U</td><td>Stitch boundary overlay error</td><td>Foundry Ops</td><td>Run 4 stitch optimization</td></tr>
  <tr><td>5</td><td>PDB BOM</td><td>$28.62/board</td><td>U</td><td>PCB stackup upgrade; PTA yield absorption</td><td>Supply Chain</td><td>BOM cost reduction review</td></tr>
</table>

**Total Unfavorable Variances:** $78,301 (excluding R&D budget variances)  

**Total Favorable Variances:** $0

### 9.2 Variance Trend Chart (Quarterly)

<table>
  <tr><th>Variance Category</th><th>Q1</th><th>Q2</th><th>Q3</th><th>Q4</th><th>Trend</th></tr>
  <tr><td>Foundry PPV</td><td>$0</td><td>$18,000 U</td><td>$0</td><td>$0</td><td>Improving</td></tr>
  <tr><td>Yield – RISC-V64</td><td>$0</td><td>$148 U</td><td>$0</td><td>$0</td><td>Stable</td></tr>
  <tr><td>Yield – GPU</td><td>$0</td><td>$533 U</td><td>$0</td><td>$0</td><td>Stable</td></tr>
  <tr><td>Yield – PTA</td><td>$0</td><td>$0</td><td>$5,353 U</td><td>$0</td><td>One-time event</td></tr>
  <tr><td>R&amp;D Labor</td><td>$163,000 U</td><td>$163,000 U</td><td>$163,000 U</td><td>$164,000 U</td><td>Stable (ongoing)</td></tr>
  <tr><td>BOM – PDB</td><td>$0</td><td>$0</td><td>$14,310 U</td><td>$0</td><td>One-time event</td></tr>
</table>

## Section 10: Variance Disposition Policy

When variances are identified, you must decide how to dispose of them. For a fabless company, the following policy applies:

<table>
  <tr><th>Variance Type</th><th>Disposition Method</th><th>Rationale</th></tr>
  <tr><td>PPV – Foundry slots</td><td>Write off to COGS in period incurred</td><td>Non-recurring; not attributable to specific inventory</td></tr>
  <tr><td>Yield variance – Chips</td><td>Absorb into inventory cost of remaining good units</td><td>Attributable to specific production run</td></tr>
  <tr><td>Labor rate variance</td><td>Write off to R&amp;D expense in period incurred</td><td>Period cost; not inventory-related</td></tr>
  <tr><td>Labor efficiency variance</td><td>Write off to R&amp;D expense in period incurred</td><td>Period cost; not inventory-related</td></tr>
  <tr><td>BOM variance – PDB</td><td>Absorb into PDB finished goods cost</td><td>Attributable to specific board production</td></tr>
  <tr><td>Overhead volume variance</td><td>Write off to COGS in period incurred</td><td>Capacity-related; not product-specific</td></tr>
  <tr><td>Overhead spending variance</td><td>Write off to R&amp;D expense in period incurred</td><td>Period cost</td></tr>
</table>

**End-of-Year Treatment:** At fiscal year-end, all remaining variance account balances are closed to Retained Earnings (or COGS, depending on materiality).

## Section 11: Key Performance Indicators (KPIs) for Variance Management

<table>
  <tr><th>KPI</th><th>Target</th><th>Current</th><th>Status</th></tr>
  <tr><td>Foundry PPV as % of foundry spend</td><td>&lt; 5%</td><td>18%</td><td>🔴</td></tr>
  <tr><td>RISC-V64 yield</td><td>≥ 95%</td><td>88%</td><td>🟡</td></tr>
  <tr><td>GPU yield</td><td>≥ 90%</td><td>78%</td><td>🔴</td></tr>
  <tr><td>PTA yield</td><td>≥ 85%</td><td>72%</td><td>🔴</td></tr>
  <tr><td>R&amp;D budget variance</td><td>&lt; 10%</td><td>64.7%</td><td>🔴</td></tr>
  <tr><td>PDB BOM variance</td><td>&lt; 5%</td><td>16.6%</td><td>🟡</td></tr>
  <tr><td>Overhead volume variance</td><td>&lt; $5,000</td><td>$15,000</td><td>🔴</td></tr>
  <tr><td>Days to close variance report</td><td>≤ 5 days</td><td>5 days</td><td>🟢</td></tr>
</table>

**Overall Variance Health Score:** 2/8 on target — Immediate management attention required on photonics yield and R&D labor budget.

## Section 12: Variance Reduction Action Plan

Based on the variance analysis, the following action plan is recommended:

<table>
  <tr><th>Priority</th><th>Action</th><th>Owner</th><th>Deadline</th><th>Expected Impact</th></tr>
  <tr><td>1</td><td>Photonics DOE run with AMF to characterize waveguide loss</td><td>Photonics Eng</td><td>Q1 2028</td><td>Improve PTA yield by 8–10 pp; reduce COY by $3,000–$4,000</td></tr>
  <tr><td>2</td><td>Integrate AMF DRC rules into AI photonic design tool</td><td>Design Automation</td><td>Q1 2028</td><td>Eliminate $3,500/iteration DRC rework cost</td></tr>
  <tr><td>3</td><td>Revise design engineer standard rates for 2027 market</td><td>HR / FP&amp;A</td><td>Q1 2028</td><td>Reduce labor rate variance by $60,000–$80,000 annually</td></tr>
  <tr><td>4</td><td>Implement stitch-aware layout constraints for GPU</td><td>Foundry Ops</td><td>Run 4 (Q2 2028)</td><td>Improve GPU yield by 5–7 pp; reduce COY by $300–$400</td></tr>
  <tr><td>5</td><td>Negotiate PCB stackup pricing with vendor</td><td>Supply Chain</td><td>Q1 2028</td><td>Reduce BOM variance by $2.00–$3.00/board</td></tr>
  <tr><td>6</td><td>Establish design freeze milestone 4 weeks before slot deadline</td><td>Program Mgmt</td><td>Immediate</td><td>Eliminate early-bird PPV of $18,000</td></tr>
  <tr><td>7</td><td>Budget for contract engineering capacity in GPU plan</td><td>FP&amp;A</td><td>Next budget cycle</td><td>Eliminate surprise labor efficiency variance of $44,000</td></tr>
</table>

This variance analysis playbook gives you a complete framework for measuring, analyzing, and acting on cost variances across your RISC-V64 SoC, GPU, PTA, and development board projects. The key insight from the analysis is that **photonics yield and R&D labor costs** are your two largest variance drivers — both require sustained management attention and cross-functional action.

---

# Rolling Forecast Template: AI Chip Development & Development Board Manufacturing

**Entity:** Gridworkz Fabless AI Chip Company  
**Forecast Cadence:** Monthly, 12-month rolling window (3+9 format → 6+6 → 9+3 → 12+0 as the fiscal year progresses)  
**Currency:** CA  
**Basis:** CA GAAP | Driver-Based Planning

## Section 1: Design Principles & Forecasting Architecture

Your rolling forecast must reflect the unique economics of a fabless semiconductor company: lumpy foundry prepayments, yield-dependent unit costs, and multi-quarter fabrication lead times. The architecture below is built on four core elements that drive effective rolling forecasts: **driver-based planning**, **scenario modeling**, **real-time data integration**, and **collaborative workflows**.

### 1.1 Forecasting Window & Rollover Logic

<table>
  <tr><th>Element</th><th>Specification</th></tr>
  <tr><td>Window</td><td>12 months forward, with 3 months of actuals + 9 months of forecast (3+9) at the start of the fiscal year</td></tr>
  <tr><td>Rollover</td><td>On month-end close, the oldest forecast month drops, the just-closed month converts to actual, and a new month is appended</td></tr>
  <tr><td>Formula</td><td>=IF(Month&lt;=LastClosedPeriod, Actual, Forecast)</td></tr>
  <tr><td>Named Ranges</td><td>Use named ranges (e.g., LastClosedPeriod, CurrentFY) to support template refreshes without breaking formulas</td></tr>
  <tr><td>Commentary</td><td>Every forecast line includes a Commentary column where the responsible owner explains changes from the prior forecast</td></tr>
</table>

### 1.2 Driver Tree for Your Business

```plaintext
Total Revenue
├── Development Board Revenue (PDB)
│   ├── Units Sold (driver: university orders, grant awards)
│   ├── Price per Board (driver: academic pricing, volume discounts)
│   └── Mix (driver: standard PDB vs. PDB with photonics support)
├── Chip Revenue (RISC-V64 SoC, GPU, PTA)
│   ├── Units Sold (driver: research org orders, sample requests)
│   └── Price per Chip (driver: die size, packaging, volume tier)
└── Grant Revenue
    ├── Grant Awards (driver: proposals submitted × win rate)
    └── Milestone Completion (driver: technical milestones achieved)

Total Cost of Revenue
├── Foundry Costs (wafer.space)
│   ├── Slot Price (driver: early bird vs. standard)
│   ├── Slots Purchased (driver: die size, reticle stitching)
│   └── Yield (driver: process maturity, design complexity)
├── Photonics Costs (GF/AMF)
│   ├── MPW Slot Cost (driver: quote, DRC iterations)
│   └── Photonics Yield (driver: grating coupler loss, waveguide loss)
└── Assembly & Test
    ├── Packaging Cost (driver: chip-on-board vs. bare die)
    └── Board BOM (driver: component pricing, PCB stackup)

Operating Expenses
├── R&D
│   ├── Design Engineering Labor (driver: headcount × rate)
│   ├── EDA Software (driver: seats × monthly rate)
│   ├── Mask & Reticle (driver: MPW runs × cost per run)
│   └── Prototype & Test (driver: lab hours × rate)
└── G&A
    ├── Legal & IP (driver: patent filings, licensing)
    └── Facilities (driver: headcount × space per person)
```

## Section 2: Driver-Based Input Sheet

This is the engine of your rolling forecast. Every forecasted number traces back to a driver in this sheet.

### 2.1 Revenue Drivers

<table>
  <tr><th>Driver</th><th>Unit</th><th>Source</th><th>M1</th><th>M2</th><th>M3</th><th>...</th><th>M12</th></tr>
  <tr><td>PDB units sold</td><td>units</td><td>Sales pipeline</td><td>10</td><td>15</td><td>20</td><td></td><td>50</td></tr>
  <tr><td>PDB price per board</td><td>$/unit</td><td>Pricing policy</td><td>$500</td><td>$500</td><td>$500</td><td></td><td>$500</td></tr>
  <tr><td>PDB revenue</td><td>$</td><td>Calc</td><td>$5,000</td><td>$7,500</td><td>$10,000</td><td></td><td>$25,000</td></tr>
  <tr><td>RISC-V64 SoC units sold</td><td>units</td><td>Research orders</td><td>50</td><td>75</td><td>100</td><td></td><td>200</td></tr>
  <tr><td>RISC-V64 SoC price per die</td><td>$/die</td><td>Pricing policy</td><td>$50</td><td>$50</td><td>$50</td><td></td><td>$50</td></tr>
  <tr><td>RISC-V64 SoC revenue</td><td>$</td><td>Calc</td><td>$2,500</td><td>$3,750</td><td>$5,000</td><td></td><td>$10,000</td></tr>
  <tr><td>GPU units sold</td><td>units</td><td>Research orders</td><td>20</td><td>30</td><td>40</td><td></td><td>80</td></tr>
  <tr><td>GPU price per die</td><td>$/die</td><td>Pricing policy</td><td>$75</td><td>$75</td><td>$75</td><td></td><td>$75</td></tr>
  <tr><td>GPU revenue</td><td>$</td><td>Calc</td><td>$1,500</td><td>$2,250</td><td>$3,000</td><td></td><td>$6,000</td></tr>
  <tr><td>PTA units sold</td><td>units</td><td>Research orders</td><td>5</td><td>8</td><td>12</td><td></td><td>25</td></tr>
  <tr><td>PTA price per chip</td><td>$/chip</td><td>Pricing policy</td><td>$1,500</td><td>$1,500</td><td>$1,500</td><td></td><td>$1,500</td></tr>
  <tr><td>PTA revenue</td><td>$</td><td>Calc</td><td>$7,500</td><td>$12,000</td><td>$18,000</td><td></td><td>$37,500</td></tr>
  <tr><td>Grant revenue</td><td>$</td><td>Grant milestones</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td></td><td>$20,833</td></tr>
  <tr><td>Total Revenue</td><td>$</td><td>Calc</td><td>$39,333</td><td>$46,333</td><td>$56,833</td><td></td><td>$99,333</td></tr>
</table>

**Formulas:**

- `PDB Revenue = PDB Units × PDB Price`
- `Total Revenue = PDB Revenue + RISC-V64 Revenue + GPU Revenue + PTA Revenue + Grant Revenue`

### 2.2 Foundry & Photonics Cost Drivers

<table>
  <tr><th>Driver</th><th>Unit</th><th>Source</th><th>M1</th><th>M2</th><th>M3</th><th>...</th><th>M12</th></tr>
  <tr><td>wafer.space slots purchased</td><td>slots</td><td>Fab manifest</td><td>0</td><td>0</td><td>3</td><td></td><td>0</td></tr>
  <tr><td>wafer.space slot price</td><td>$/slot</td><td>Quote</td><td>$2,000</td><td>$2,000</td><td>$2,000</td><td></td><td>$2,000</td></tr>
  <tr><td>wafer.space fabrication cost</td><td>$</td><td>Calc</td><td>$0</td><td>$0</td><td>$6,000</td><td></td><td>$0</td></tr>
  <tr><td>GF/AMF photonics slots</td><td>slots</td><td>Fab manifest</td><td>0</td><td>0</td><td>0</td><td></td><td>1</td></tr>
  <tr><td>GF/AMF photonics slot price</td><td>$/slot</td><td>Quote</td><td>$35,000</td><td>$35,000</td><td>$35,000</td><td></td><td>$35,000</td></tr>
  <tr><td>GF/AMF photonics cost</td><td>$</td><td>Calc</td><td>$0</td><td>$0</td><td>$0</td><td></td><td>$35,000</td></tr>
  <tr><td>RISC-V64 SoC yield</td><td>%</td><td>Foundry Ops</td><td>95%</td><td>95%</td><td>95%</td><td></td><td>95%</td></tr>
  <tr><td>GPU yield</td><td>%</td><td>Foundry Ops</td><td>90%</td><td>90%</td><td>90%</td><td></td><td>90%</td></tr>
  <tr><td>PTA yield</td><td>%</td><td>Photonics Eng</td><td>85%</td><td>85%</td><td>85%</td><td></td><td>85%</td></tr>
  <tr><td>Chip-on-board packaging cost</td><td>$/die</td><td>wafer.space</td><td>$1.50</td><td>$1.50</td><td>$1.50</td><td></td><td>$1.50</td></tr>
  <tr><td>Assembly labor cost per board</td><td>$/board</td><td>CM quote</td><td>$24</td><td>$24</td><td>$24</td><td></td><td>$24</td></tr>
  <tr><td>Board BOM cost (excl. chips)</td><td>$/board</td><td>Supply Chain</td><td>$56</td><td>$56</td><td>$56</td><td></td><td>$56</td></tr>
</table>

**Formulas:**

- `wafer.space Fabrication Cost = Slots Purchased × Slot Price`
- `GF/AMF Photonics Cost = Photonics Slots × Photonics Slot Price`
- `RISC-V64 Cost per Good Die = (Slot Price ÷ (Expected Dies × Yield)) + Packaging Cost`
- `PTA Cost per Good Chip = (Photonics Slot Price ÷ (Expected Chips × Photonics Yield))`

### 2.3 R&D & Operating Expense Drivers

<table>
  <tr><th>Driver</th><th>Unit</th><th>Source</th><th>M1</th><th>M2</th><th>M3</th><th>...</th><th>M12</th></tr>
  <tr><td>Design engineers (FTE)</td><td>headcount</td><td>HR plan</td><td>5</td><td>5</td><td>5</td><td></td><td>7</td></tr>
  <tr><td>Fully loaded rate per engineer</td><td>$/month</td><td>HR</td><td>$16,250</td><td>$16,250</td><td>$16,250</td><td></td><td>$16,250</td></tr>
  <tr><td>Contract engineers</td><td>headcount</td><td>Engineering</td><td>2</td><td>2</td><td>2</td><td></td><td>0</td></tr>
  <tr><td>Contract engineer rate</td><td>$/month</td><td>Procurement</td><td>$22,000</td><td>$22,000</td><td>$22,000</td><td></td><td>$22,000</td></tr>
  <tr><td>EDA software seats</td><td>seats</td><td>IT</td><td>5</td><td>5</td><td>5</td><td></td><td>7</td></tr>
  <tr><td>EDA cost per seat</td><td>$/month</td><td>Vendor</td><td>$2,500</td><td>$2,500</td><td>$2,500</td><td></td><td>$2,500</td></tr>
  <tr><td>Mask &amp; reticle cost per run</td><td>$/run</td><td>wafer.space</td><td>$7,500</td><td>$7,500</td><td>$7,500</td><td></td><td>$0</td></tr>
  <tr><td>Prototype &amp; test hours</td><td>hours</td><td>Lab</td><td>200</td><td>200</td><td>200</td><td></td><td>300</td></tr>
  <tr><td>Prototype &amp; test rate</td><td>$/hour</td><td>Lab</td><td>$40</td><td>$40</td><td>$40</td><td></td><td>$40</td></tr>
  <tr><td>PCB NRE costs</td><td>$</td><td>Supply Chain</td><td>$0</td><td>$0</td><td>$0</td><td></td><td>$15,000</td></tr>
  <tr><td>Legal &amp; IP</td><td>$</td><td>Legal</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td></td><td>$8,000</td></tr>
  <tr><td>Facilities</td><td>$</td><td>Ops</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td></td><td>$12,000</td></tr>
</table>

**Formulas:**

- `Design Labor Cost = (FTE × Rate) + (Contract Engineers × Contract Rate)`
- `EDA Cost = Seats × Cost per Seat`
- `Prototype & Test Cost = Hours × Rate`

## Section 3: Rolling Forecast P&L Template

### 3.1 Monthly Rolling Forecast — Income Statement

<table>
  <tr><th>Line Item</th><th>M1 (Act)</th><th>M2 (Act)</th><th>M3 (Fcst)</th><th>M4 (Fcst)</th><th>M5 (Fcst)</th><th>M6 (Fcst)</th><th>...</th><th>M12 (Fcst)</th><th>FY Total</th></tr>
  <tr><td>Revenue</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>PDB Board Sales</td><td>$5,000</td><td>$7,500</td><td>$10,000</td><td>$12,500</td><td>$15,000</td><td>$17,500</td><td></td><td>$25,000</td><td>$92,500</td></tr>
  <tr><td>RISC-V64 SoC Sales</td><td>$2,500</td><td>$3,750</td><td>$5,000</td><td>$6,250</td><td>$7,500</td><td>$8,750</td><td></td><td>$10,000</td><td>$44,000</td></tr>
  <tr><td>GPU Sales</td><td>$1,500</td><td>$2,250</td><td>$3,000</td><td>$3,750</td><td>$4,500</td><td>$5,250</td><td></td><td>$6,000</td><td>$26,250</td></tr>
  <tr><td>PTA Sales</td><td>$7,500</td><td>$12,000</td><td>$18,000</td><td>$22,500</td><td>$27,000</td><td>$31,500</td><td></td><td>$37,500</td><td>$156,000</td></tr>
  <tr><td>Grant Revenue</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td></td><td>$20,833</td><td>$250,000</td></tr>
  <tr><td>Total Revenue</td><td>$37,333</td><td>$46,333</td><td>$56,833</td><td>$65,833</td><td>$74,833</td><td>$83,833</td><td></td><td>$99,333</td><td>$568,750</td></tr>
  <tr><td>Cost of Revenue</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Foundry — wafer.space</td><td>$0</td><td>$0</td><td>$6,000</td><td>$6,000</td><td>$6,000</td><td>$6,000</td><td></td><td>$0</td><td>$24,000</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td></td><td>$35,000</td><td>$35,000</td></tr>
  <tr><td>Assembly &amp; Test</td><td>$2,000</td><td>$2,500</td><td>$3,000</td><td>$3,500</td><td>$4,000</td><td>$4,500</td><td></td><td>$5,500</td><td>$25,000</td></tr>
  <tr><td>Board BOM</td><td>$2,800</td><td>$3,500</td><td>$4,200</td><td>$4,900</td><td>$5,600</td><td>$6,300</td><td></td><td>$7,700</td><td>$35,000</td></tr>
  <tr><td>Total COGS</td><td>$4,800</td><td>$6,000</td><td>$13,200</td><td>$14,400</td><td>$15,600</td><td>$16,800</td><td></td><td>$48,200</td><td>$119,000</td></tr>
  <tr><td>Gross Profit</td><td>$32,533</td><td>$40,333</td><td>$43,633</td><td>$51,433</td><td>$59,233</td><td>$67,033</td><td></td><td>$51,133</td><td>$449,750</td></tr>
  <tr><td>Gross Margin %</td><td>87.1%</td><td>87.1%</td><td>76.8%</td><td>78.1%</td><td>79.2%</td><td>80.0%</td><td></td><td>51.5%</td><td>79.1%</td></tr>
  <tr><td>Operating Expenses</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>R&amp;D — Design Labor</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td></td><td>$113,750</td><td>$1,488,000</td></tr>
  <tr><td>R&amp;D — EDA Software</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td></td><td>$17,500</td><td>$152,000</td></tr>
  <tr><td>R&amp;D — Mask &amp; Reticle</td><td>$0</td><td>$0</td><td>$7,500</td><td>$0</td><td>$0</td><td>$7,500</td><td></td><td>$0</td><td>$22,500</td></tr>
  <tr><td>R&amp;D — Prototype &amp; Test</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td></td><td>$12,000</td><td>$100,000</td></tr>
  <tr><td>R&amp;D — PCB Development</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td></td><td>$15,000</td><td>$15,000</td></tr>
  <tr><td>Total R&amp;D</td><td>$145,750</td><td>$145,750</td><td>$153,250</td><td>$145,750</td><td>$145,750</td><td>$153,250</td><td></td><td>$158,250</td><td>$1,777,500</td></tr>
  <tr><td>G&amp;A — Legal &amp; IP</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td></td><td>$8,000</td><td>$96,000</td></tr>
  <tr><td>G&amp;A — Facilities</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td></td><td>$12,000</td><td>$144,000</td></tr>
  <tr><td>Total G&amp;A</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td></td><td>$20,000</td><td>$240,000</td></tr>
  <tr><td>Total OpEx</td><td>$165,750</td><td>$165,750</td><td>$173,250</td><td>$165,750</td><td>$165,750</td><td>$173,250</td><td></td><td>$178,250</td><td>$2,017,500</td></tr>
  <tr><td>EBIT</td><td>($133,217)</td><td>($125,417)</td><td>($129,617)</td><td>($114,317)</td><td>($106,517)</td><td>($106,217)</td><td></td><td>($127,117)</td><td>($1,567,750)</td></tr>
  <tr><td>EBITDA</td><td>($131,217)</td><td>($123,417)</td><td>($127,617)</td><td>($112,317)</td><td>($104,517)</td><td>($104,217)</td><td></td><td>($125,117)</td><td>($1,552,750)</td></tr>
</table>

**Note:** The FY Total column is the sum of the 12-month rolling window, not a fiscal year total. As the window rolls forward, this total shifts.

### 3.2 Quarterly Rolling Forecast Summary

<table>
  <tr><th>Metric</th><th>Q1 (3+9)</th><th>Q2 (6+6)</th><th>Q3 (9+3)</th><th>Q4 (12+0)</th></tr>
  <tr><td>Revenue</td><td>$140,499</td><td>$206,499</td><td>$278,499</td><td>$568,750</td></tr>
  <tr><td>Gross Profit</td><td>$116,499</td><td>$168,299</td><td>$228,699</td><td>$449,750</td></tr>
  <tr><td>Gross Margin %</td><td>82.9%</td><td>81.5%</td><td>82.1%</td><td>79.1%</td></tr>
  <tr><td>R&amp;D</td><td>$444,750</td><td>$444,750</td><td>$450,000</td><td>$1,777,500</td></tr>
  <tr><td>EBITDA</td><td>($382,251)</td><td>($338,251)</td><td>($312,751)</td><td>($1,552,750)</td></tr>
  <tr><td>Cash Burn</td><td>($382,251)</td><td>($338,251)</td><td>($312,751)</td><td>($1,552,750)</td></tr>
</table>

**Key insight:** The Q4 (12+0) column shows a full-year view with the photonics slot cost ($35,000) hitting in a single month, causing a visible gross margin dip. This is the "lumpy" nature of fabless semiconductor economics — tape-out costs are expensed as incurred, not capitalized, making R&D and COGS volatile on a monthly basis.

## Section 4: Rolling Cash Flow Forecast

Cash flow visibility is critical for a fabless company, especially given supplier prepayments. Fabless companies often make significant prepayments to secure foundry capacity, and these prepayments can have a material impact on free cash flow even when EBITDA is strong.

### 4.1 Monthly Cash Flow Forecast

<table>
  <tr><th>Line Item</th><th>M1</th><th>M2</th><th>M3</th><th>M4</th><th>M5</th><th>M6</th><th>...</th><th>M12</th></tr>
  <tr><td>Beginning Cash</td><td>$2,500,000</td><td>$2,117,749</td><td>$1,992,332</td><td>$1,862,715</td><td>$1,748,398</td><td>$1,641,881</td><td></td><td>$1,205,000</td></tr>
  <tr><td>Cash Inflows</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Board &amp; Chip Sales</td><td>$3,000</td><td>$4,500</td><td>$6,000</td><td>$7,500</td><td>$9,000</td><td>$10,500</td><td></td><td>$15,000</td></tr>
  <tr><td>Grant Receipts</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td></td><td>$20,833</td></tr>
  <tr><td>Total Inflows</td><td>$23,833</td><td>$25,333</td><td>$26,833</td><td>$28,333</td><td>$29,833</td><td>$31,333</td><td></td><td>$35,833</td></tr>
  <tr><td>Cash Outflows</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Foundry Prepayments</td><td>$0</td><td>$0</td><td>$6,000</td><td>$0</td><td>$0</td><td>$6,000</td><td></td><td>$0</td></tr>
  <tr><td>Photonics Prepayments</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td></td><td>$35,000</td></tr>
  <tr><td>R&amp;D Payroll</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td></td><td>$113,750</td></tr>
  <tr><td>EDA Software</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td></td><td>$17,500</td></tr>
  <tr><td>Prototype &amp; Test</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td></td><td>$12,000</td></tr>
  <tr><td>Board BOM &amp; Assembly</td><td>$4,800</td><td>$6,000</td><td>$7,200</td><td>$8,400</td><td>$9,600</td><td>$10,800</td><td></td><td>$13,200</td></tr>
  <tr><td>G&amp;A</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td></td><td>$20,000</td></tr>
  <tr><td>Total Outflows</td><td>$170,550</td><td>$171,750</td><td>$178,950</td><td>$174,150</td><td>$175,350</td><td>$182,550</td><td></td><td>$211,450</td></tr>
  <tr><td>Net Cash Flow</td><td>($146,717)</td><td>($146,417)</td><td>($152,117)</td><td>($145,817)</td><td>($145,517)</td><td>($151,217)</td><td></td><td>($175,617)</td></tr>
  <tr><td>Ending Cash</td><td>$2,353,283</td><td>$2,206,866</td><td>$2,054,749</td><td>$1,908,932</td><td>$1,763,415</td><td>$1,612,198</td><td></td><td>$1,029,383</td></tr>
</table>

### 4.2 Cash Runway Dashboard

<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>Beginning cash</td><td>$2,500,000</td></tr>
  <tr><td>Monthly burn rate (avg)</td><td>$150,000</td></tr>
  <tr><td>Cash runway (months)</td><td>16.7 months</td></tr>
  <tr><td>Months to next foundry prepayment</td><td>3 months</td></tr>
  <tr><td>Months to photonics prepayment</td><td>12 months</td></tr>
  <tr><td>Critical cash threshold</td><td>$500,000</td></tr>
  <tr><td>Months to critical threshold</td><td>13.3 months</td></tr>
</table>

**Alert:** If the photonics MPW run is moved earlier (e.g., from M12 to M9), the cash runway shortens by 3 months. This is a **trigger point** for either accelerating grant receipts or securing additional funding.

## Section 5: Scenario Analysis

Rolling forecasts should include scenario modeling to stress-test assumptions. The template supports three scenarios: **Base**, **Conservative**, and **Aggressive**.

### 5.1 Scenario Drivers

<table>
  <tr><th>Driver</th><th>Conservative</th><th>Base</th><th>Aggressive</th></tr>
  <tr><td>PDB price per board</td><td>$400</td><td>$500</td><td>$600</td></tr>
  <tr><td>PDB units (monthly avg)</td><td>10</td><td>20</td><td>35</td></tr>
  <tr><td>RISC-V64 SoC yield</td><td>85%</td><td>95%</td><td>98%</td></tr>
  <tr><td>GPU yield</td><td>75%</td><td>90%</td><td>95%</td></tr>
  <tr><td>PTA yield</td><td>65%</td><td>85%</td><td>92%</td></tr>
  <tr><td>Photonics slot cost</td><td>$45,000</td><td>$35,000</td><td>$30,000</td></tr>
  <tr><td>Design engineer headcount</td><td>7</td><td>5</td><td>5</td></tr>
  <tr><td>Contract engineers</td><td>3</td><td>2</td><td>0</td></tr>
  <tr><td>Grant revenue</td><td>$150,000</td><td>$250,000</td><td>$400,000</td></tr>
</table>

### 5.2 Scenario Comparison — FY EBITDA

<table>
  <tr><th>Scenario</th><th>Revenue</th><th>Gross Margin %</th><th>R&amp;D</th><th>EBITDA</th><th>Cash Runway</th></tr>
  <tr><td>Conservative</td><td>$420,000</td><td>65.0%</td><td>$2,100,000</td><td>($1,827,000)</td><td>11.2 months</td></tr>
  <tr><td>Base</td><td>$568,750</td><td>79.1%</td><td>$1,777,500</td><td>($1,552,750)</td><td>16.7 months</td></tr>
  <tr><td>Aggressive</td><td>$750,000</td><td>84.0%</td><td>$1,500,000</td><td>($1,050,000)</td><td>24.5 months</td></tr>
</table>

**Key insight:** The Conservative scenario shows that a 10-percentage-point drop in PTA yield (from 85% to 65%) combined with higher foundry costs can reduce cash runway by nearly 6 months. This is why photonics yield is the single most important driver to monitor.

## Section 6: Rolling Forecast Dashboard

### 6.1 Executive KPI Dashboard

<table>
  <tr><th>KPI</th><th>M1</th><th>M2</th><th>M3</th><th>M4</th><th>M5</th><th>M6</th><th>Target</th><th>Status</th></tr>
  <tr><td>Revenue</td><td>$37,333</td><td>$46,333</td><td>$56,833</td><td>$65,833</td><td>$74,833</td><td>$83,833</td><td>$75,000/mo</td><td>🟡</td></tr>
  <tr><td>Gross Margin %</td><td>87.1%</td><td>87.1%</td><td>76.8%</td><td>78.1%</td><td>79.2%</td><td>80.0%</td><td>≥80%</td><td>🟡</td></tr>
  <tr><td>R&amp;D Spend</td><td>$145,750</td><td>$145,750</td><td>$153,250</td><td>$145,750</td><td>$145,750</td><td>$153,250</td><td>≤$150,000/mo</td><td>🟡</td></tr>
  <tr><td>EBITDA</td><td>($133,217)</td><td>($125,417)</td><td>($129,617)</td><td>($114,317)</td><td>($106,517)</td><td>($106,217)</td><td>≥($150,000)</td><td>🟢</td></tr>
  <tr><td>Cash Balance</td><td>$2,353,283</td><td>$2,206,866</td><td>$2,054,749</td><td>$1,908,932</td><td>$1,763,415</td><td>$1,612,198</td><td>≥$1,000,000</td><td>🟢</td></tr>
  <tr><td>Runway (months)</td><td>16.7</td><td>15.9</td><td>14.9</td><td>14.1</td><td>13.4</td><td>12.7</td><td>≥12</td><td>🟡</td></tr>
  <tr><td>PTA Yield</td><td>85%</td><td>85%</td><td>85%</td><td>85%</td><td>85%</td><td>85%</td><td>≥85%</td><td>🟢</td></tr>
  <tr><td>GPU Yield</td><td>90%</td><td>90%</td><td>90%</td><td>90%</td><td>90%</td><td>90%</td><td>≥90%</td><td>🟢</td></tr>
  <tr><td>RISC-V64 Yield</td><td>95%</td><td>95%</td><td>95%</td><td>95%</td><td>95%</td><td>95%</td><td>≥95%</td><td>🟢</td></tr>
</table>

### 6.2 Variance-to-Forecast Bridge (Month-End)

This bridge explains why actual results differ from the prior month's forecast.

<table>
  <tr><th>Bridge Item</th><th>Amount</th><th>Explanation</th></tr>
  <tr><td>Prior forecast — M1 EBITDA</td><td>($130,000)</td><td>Forecast from previous month</td></tr>
  <tr><td>Revenue variance</td><td>+$2,667</td><td>Higher than expected board sales (12 units vs. 10 forecasted)</td></tr>
  <tr><td>Yield variance — RISC-V64</td><td>($148)</td><td>88% actual vs. 95% forecasted</td></tr>
  <tr><td>Yield variance — PTA</td><td>($5,353)</td><td>72% actual vs. 85% forecasted</td></tr>
  <tr><td>Labor rate variance</td><td>($10,415)</td><td>AI talent premium</td></tr>
  <tr><td>Labor efficiency variance</td><td>($44,000)</td><td>Contract engineers for GPU acceleration</td></tr>
  <tr><td>Actual — M1 EBITDA</td><td>($133,217)</td><td>Net variance: ($3,217) U</td></tr>
</table>

**Root cause tags:**

- `YIELD-PTA`: Photonics yield miss due to grating coupler loss
- `LABOR-RATE`: Design engineer market rate above standard
- `LABOR-EFF`: Contract engineers for GPU acceleration

## Section 7: Monthly Rolling Forecast Process

### 7.1 Monthly Close & Rollover Checklist

<table>
  <tr><th>Step</th><th>Activity</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td>Close the prior month (accruals, prepayments, WIP reconciliation)</td><td>Accounting</td><td>Day 3</td></tr>
  <tr><td>2</td><td>Pull actuals into the rolling forecast (revenue, COGS, R&amp;D, cash)</td><td>FP&amp;A</td><td>Day 4</td></tr>
  <tr><td>3</td><td>Calculate variances vs. prior forecast for all driver lines</td><td>FP&amp;A</td><td>Day 4</td></tr>
  <tr><td>4</td><td>Update driver assumptions for the new forecast month (M+12)</td><td>Department heads</td><td>Day 5</td></tr>
  <tr><td>5</td><td>Review variance-to-forecast bridge with CFO and CTO</td><td>Finance</td><td>Day 6</td></tr>
  <tr><td>6</td><td>Update scenario weights based on latest yield data and grant pipeline</td><td>FP&amp;A</td><td>Day 6</td></tr>
  <tr><td>7</td><td>Roll the window forward: drop oldest month, add new forecast month</td><td>FP&amp;A</td><td>Day 7</td></tr>
  <tr><td>8</td><td>Refresh dashboard and distribute to leadership</td><td>FP&amp;A</td><td>Day 8</td></tr>
  <tr><td>9</td><td>Update cash runway projection and alert if below 12 months</td><td>Treasury</td><td>Day 8</td></tr>
  <tr><td>10</td><td>Archive prior forecast version for trend analysis</td><td>FP&amp;A</td><td>Day 9</td></tr>
</table>

### 7.2 Forecast Accuracy Tracking

Use Vena-style reporting to compare forecast vs. actuals and track accuracy trends over time.

<table>
  <tr><th>Month</th><th>Forecast EBITDA</th><th>Actual EBITDA</th><th>Variance</th><th>Accuracy %</th></tr>
  <tr><td>M1</td><td>($130,000)</td><td>($133,217)</td><td>($3,217)</td><td>97.6%</td></tr>
  <tr><td>M2</td><td>($125,000)</td><td>($125,417)</td><td>($417)</td><td>99.7%</td></tr>
  <tr><td>M3</td><td>($128,000)</td><td>($129,617)</td><td>($1,617)</td><td>98.7%</td></tr>
  <tr><td>M4</td><td>($112,000)</td><td>($114,317)</td><td>($2,317)</td><td>98.0%</td></tr>
  <tr><td>M5</td><td>($105,000)</td><td>($106,517)</td><td>($1,517)</td><td>98.6%</td></tr>
  <tr><td>M6</td><td>($104,000)</td><td>($106,217)</td><td>($2,217)</td><td>97.9%</td></tr>
</table>

**Target:** Maintain forecast accuracy ≥ 95% for EBITDA and ≥ 90% for revenue.

**Commentary field (example):**

> *"M1 EBITDA variance of ($3,217) was driven primarily by the PTA photonics yield miss (72% vs. 85% forecasted). The yield gap was caused by grating coupler insertion loss exceeding the AMF model prediction. Corrective action: DOE run scheduled for Q1 2028 to characterize waveguide loss at AMF."*

## Section 8: Excel Formula Reference

### 8.1 Rollover Formula

```plaintext
=IF(MonthNumber <= LastClosedPeriod, ActualValue, ForecastValue)
```

**Named Ranges:**

- `LastClosedPeriod` = the month number of the most recently closed period (e.g., 3 for March)
- `CurrentFY` = the current fiscal year

### 8.2 Driver Calculation Formulas

```plaintext
' Revenue
PDB_Revenue = PDB_Units * PDB_Price
RISC_V_Revenue = RISC_V_Units * RISC_V_Price
Total_Revenue = SUM(PDB_Revenue, RISC_V_Revenue, GPU_Revenue, PTA_Revenue, Grant_Revenue)

' Cost of Revenue
wafer_space_Cost = wafer_space_Slots * wafer_space_Slot_Price
GF_AMF_Cost = GF_AMF_Slots * GF_AMF_Slot_Price
RISC_V_Cost_Per_Die = (wafer_space_Slot_Price / (Expected_Dies * RISC_V_Yield)) + Packaging_Cost
PTA_Cost_Per_Chip = (GF_AMF_Slot_Price / (Expected_Chips * PTA_Yield))

' R&D
Design_Labor = (FTE * Rate) + (Contract_Engineers * Contract_Rate)
EDA_Cost = Seats * Cost_Per_Seat
Prototype_Test = Hours * Rate

' Cash Flow
Net_Cash_Flow = Total_Inflows - Total_Outflows
Ending_Cash = Beginning_Cash + Net_Cash_Flow
Runway_Months = Ending_Cash / Average_Monthly_Burn
```

### 8.3 Variance Bridge Formula

```plaintext
Variance = Actual - Forecast
Variance_Pct = (Actual - Forecast) / Forecast
```

### 8.4 Scenario Toggle Formula

```plaintext
=IF(Scenario = "Conservative", Conservative_Driver, IF(Scenario = "Base", Base_Driver, Aggressive_Driver))
```

## Section 9: Key Forecasting Policies

<table>
  <tr><th>Policy</th><th>Specification</th></tr>
  <tr><td>Forecast window</td><td>12 months forward, monthly cadence</td></tr>
  <tr><td>Rollover method</td><td>Drop oldest month, add new forecast month on Day 7 of close</td></tr>
  <tr><td>Version control</td><td>Every forecast version is archived with a date stamp for trend analysis</td></tr>
  <tr><td>Commentary requirement</td><td>Any variance &gt; 5% or &gt; $5,000 requires a written explanation</td></tr>
  <tr><td>Scenario refresh</td><td>Scenarios are re-weighted quarterly based on yield data and grant pipeline</td></tr>
  <tr><td>Cash runway alert</td><td>Trigger CFO escalation if projected runway falls below 12 months</td></tr>
  <tr><td>Foundry prepayment tracking</td><td>Separate line item in cash flow forecast; alert 60 days before due</td></tr>
  <tr><td>Grant revenue recognition</td><td>Milestone-based; forecast updated monthly as milestones are achieved</td></tr>
  <tr><td>Yield assumption review</td><td>Yield drivers are reviewed monthly with Foundry Ops and Photonics Eng</td></tr>
</table>

## Section 10: Implementation Roadmap

<table>
  <tr><th>Phase</th><th>Activity</th><th>Timeline</th><th>Owner</th></tr>
  <tr><td>Phase 1</td><td>Build driver input sheet and standard cost cards</td><td>Week 1–2</td><td>FP&amp;A</td></tr>
  <tr><td>Phase 2</td><td>Build rolling P&amp;L template with rollover formulas</td><td>Week 2–3</td><td>FP&amp;A</td></tr>
  <tr><td>Phase 3</td><td>Build cash flow forecast and runway dashboard</td><td>Week 3–4</td><td>FP&amp;A / Treasury</td></tr>
  <tr><td>Phase 4</td><td>Build scenario analysis and variance bridge</td><td>Week 4–5</td><td>FP&amp;A</td></tr>
  <tr><td>Phase 5</td><td>Integrate with accounting system for actuals pull</td><td>Week 5–6</td><td>IT / Accounting</td></tr>
  <tr><td>Phase 6</td><td>Train department heads on driver updates</td><td>Week 6</td><td>FP&amp;A</td></tr>
  <tr><td>Phase 7</td><td>Run first monthly close with rolling forecast</td><td>Week 7</td><td>All</td></tr>
  <tr><td>Phase 8</td><td>Review accuracy and refine</td><td>Week 8+</td><td>FP&amp;A</td></tr>
</table>

---

This rolling forecast template gives you a complete, driver-based framework that integrates your variance analysis directly into forward-looking projections. The key insight is that **PTA photonics yield** and **cash runway** are your two most critical forecast drivers — both should be reviewed monthly with the CTO and CFO.

---

# Board-Ready Financial Summary

**Entity:** Gridworkz Fabless AI Chip Company  
**Board Meeting Date:** [Insert Date]  
**Reporting Period:** [Month/Quarter] [Year]  
**Prepared by:** CFO  
**Classification:** Confidential — Board of Directors Only

## Page 1: Executive Summary

### 1.1 One-Page Financial Snapshot

<table>
  <tr><th>Metric</th><th>Current Period</th><th>Prior Period</th><th>Variance</th><th>Plan</th><th>vs. Plan</th></tr>
  <tr><td>Revenue</td><td>$56,833</td><td>$46,333</td><td>+$10,500 F</td><td>$55,000</td><td>+$1,833 F</td></tr>
  <tr><td>Gross Margin %</td><td>76.8%</td><td>87.1%</td><td>−10.3 pp</td><td>80.0%</td><td>−3.2 pp</td></tr>
  <tr><td>R&amp;D Spend</td><td>$153,250</td><td>$145,750</td><td>+$7,500 U</td><td>$150,000</td><td>+$3,250 U</td></tr>
  <tr><td>EBITDA</td><td>($129,617)</td><td>($125,417)</td><td>−$4,200 U</td><td>($125,000)</td><td>−$4,617 U</td></tr>
  <tr><td>Cash Balance</td><td>$2,054,749</td><td>$2,206,866</td><td>−$152,117</td><td>$2,100,000</td><td>−$45,251 U</td></tr>
  <tr><td>Cash Runway (months)</td><td>14.9</td><td>15.9</td><td>−1.0</td><td>≥12</td><td>🟢</td></tr>
</table>

### 1.2 CEO/CFO Commentary (3–5 Bullets)

- **Revenue beat plan** by $1,833, driven by stronger-than-expected PTA photonic chip orders from two new research university customers. Board sales were in line with plan at 20 units.
- **Gross margin compressed** to 76.8% (vs. 80.0% plan) due to the PTA photonics yield miss (72% actual vs. 85% standard). This single variance accounts for $5,353 of unfavorable COGS.
- **R&D spend is $3,250 over plan**, primarily from contract engineering capacity added to accelerate the GPU design through reticle stitching complexity. This is a deliberate investment to protect the Q2 2027 chip delivery milestone.
- **Cash runway remains healthy at 14.9 months**, but the GF/AMF photonics prepayment ($35,000) in M12 will reduce runway by approximately 0.5 months. No immediate financing need.
- **Key ask of the Board:** Approve the Q1 2028 photonics DOE run with AMF ($45,000) to characterize waveguide loss and close the yield gap. This is the single highest-ROI action available to improve gross margin.

### 1.3 Traffic Light Dashboard

<table>
  <tr><th>Category</th><th>Status</th><th>Trend</th><th>Note</th></tr>
  <tr><td>Revenue growth</td><td>🟢</td><td>↑</td><td>22.7% month-over-month</td></tr>
  <tr><td>Gross margin</td><td>🔴</td><td>↓</td><td>PTA yield drag</td></tr>
  <tr><td>R&amp;D discipline</td><td>🟡</td><td>→</td><td>Contract engineering premium</td></tr>
  <tr><td>Cash position</td><td>🟢</td><td>↓</td><td>14.9 months runway</td></tr>
  <tr><td>Foundry execution</td><td>🟡</td><td>→</td><td>GPU stitching yield at 78%</td></tr>
  <tr><td>Photonics execution</td><td>🔴</td><td>↓</td><td>PTA yield at 72%</td></tr>
  <tr><td>Grant pipeline</td><td>🟢</td><td>↑</td><td>2 new proposals submitted</td></tr>
</table>

## Page 2: Financial Statements Summary

### 2.1 Condensed Income Statement

<table>
  <tr><th>Line Item</th><th>Current Month</th><th>Prior Month</th><th>3-Month Avg</th><th>FY Plan</th><th>FY Forecast</th><th>vs. Plan</th></tr>
  <tr><td>Revenue</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>PDB Board Sales</td><td>$10,000</td><td>$7,500</td><td>$7,500</td><td>$92,500</td><td>$92,500</td><td>—</td></tr>
  <tr><td>RISC-V64 SoC Sales</td><td>$5,000</td><td>$3,750</td><td>$3,750</td><td>$44,000</td><td>$44,000</td><td>—</td></tr>
  <tr><td>GPU Sales</td><td>$3,000</td><td>$2,250</td><td>$2,250</td><td>$26,250</td><td>$26,250</td><td>—</td></tr>
  <tr><td>PTA Sales</td><td>$18,000</td><td>$12,000</td><td>$12,500</td><td>$156,000</td><td>$156,000</td><td>—</td></tr>
  <tr><td>Grant Revenue</td><td>$20,833</td><td>$20,833</td><td>$20,833</td><td>$250,000</td><td>$250,000</td><td>—</td></tr>
  <tr><td>Total Revenue</td><td>$56,833</td><td>$46,333</td><td>$46,833</td><td>$568,750</td><td>$568,750</td><td>—</td></tr>
  <tr><td>Cost of Revenue</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Foundry — wafer.space</td><td>$6,000</td><td>$0</td><td>$2,000</td><td>$24,000</td><td>$24,000</td><td>—</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$0</td><td>$0</td><td>$0</td><td>$35,000</td><td>$35,000</td><td>—</td></tr>
  <tr><td>Assembly &amp; Test</td><td>$3,000</td><td>$2,500</td><td>$2,667</td><td>$25,000</td><td>$25,000</td><td>—</td></tr>
  <tr><td>Board BOM</td><td>$4,200</td><td>$3,500</td><td>$3,500</td><td>$35,000</td><td>$35,000</td><td>—</td></tr>
  <tr><td>Total COGS</td><td>$13,200</td><td>$6,000</td><td>$8,167</td><td>$119,000</td><td>$119,000</td><td>—</td></tr>
  <tr><td>Gross Profit</td><td>$43,633</td><td>$40,333</td><td>$38,666</td><td>$449,750</td><td>$449,750</td><td>—</td></tr>
  <tr><td>Gross Margin %</td><td>76.8%</td><td>87.1%</td><td>82.6%</td><td>79.1%</td><td>79.1%</td><td>—</td></tr>
  <tr><td>Operating Expenses</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>R&amp;D — Design Labor</td><td>$125,250</td><td>$125,250</td><td>$125,250</td><td>$1,488,000</td><td>$1,488,000</td><td>—</td></tr>
  <tr><td>R&amp;D — EDA Software</td><td>$12,500</td><td>$12,500</td><td>$12,500</td><td>$152,000</td><td>$152,000</td><td>—</td></tr>
  <tr><td>R&amp;D — Mask &amp; Reticle</td><td>$7,500</td><td>$0</td><td>$2,500</td><td>$22,500</td><td>$22,500</td><td>—</td></tr>
  <tr><td>R&amp;D — Prototype &amp; Test</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$100,000</td><td>$100,000</td><td>—</td></tr>
  <tr><td>R&amp;D — PCB Development</td><td>$0</td><td>$0</td><td>$0</td><td>$15,000</td><td>$15,000</td><td>—</td></tr>
  <tr><td>Total R&amp;D</td><td>$153,250</td><td>$145,750</td><td>$148,250</td><td>$1,777,500</td><td>$1,777,500</td><td>—</td></tr>
  <tr><td>G&amp;A — Legal &amp; IP</td><td>$8,000</td><td>$8,000</td><td>$8,000</td><td>$96,000</td><td>$96,000</td><td>—</td></tr>
  <tr><td>G&amp;A — Facilities</td><td>$12,000</td><td>$12,000</td><td>$12,000</td><td>$144,000</td><td>$144,000</td><td>—</td></tr>
  <tr><td>Total G&amp;A</td><td>$20,000</td><td>$20,000</td><td>$20,000</td><td>$240,000</td><td>$240,000</td><td>—</td></tr>
  <tr><td>Total OpEx</td><td>$173,250</td><td>$165,750</td><td>$168,250</td><td>$2,017,500</td><td>$2,017,500</td><td>—</td></tr>
  <tr><td>EBIT</td><td>($129,617)</td><td>($125,417)</td><td>($129,584)</td><td>($1,567,750)</td><td>($1,567,750)</td><td>—</td></tr>
  <tr><td>EBITDA</td><td>($127,617)</td><td>($123,417)</td><td>($127,584)</td><td>($1,552,750)</td><td>($1,552,750)</td><td>—</td></tr>
  <tr><td>EBITDA Margin %</td><td>−224.6%</td><td>−266.4%</td><td>−272.4%</td><td>−273.0%</td><td>−273.0%</td><td>—</td></tr>
</table>

### 2.2 Condensed Balance Sheet

<table>
  <tr><th>Line Item</th><th>Current Month</th><th>Prior Month</th><th>Change</th></tr>
  <tr><td>Assets</td><td></td><td></td><td></td></tr>
  <tr><td>Cash – Operating</td><td>$2,054,749</td><td>$2,206,866</td><td>−$152,117</td></tr>
  <tr><td>Accounts Receivable</td><td>$45,000</td><td>$38,000</td><td>+$7,000</td></tr>
  <tr><td>Prepaid Foundry Costs</td><td>$6,000</td><td>$0</td><td>+$6,000</td></tr>
  <tr><td>Prepaid Photonics Costs</td><td>$35,000</td><td>$35,000</td><td>—</td></tr>
  <tr><td>WIP – Foundry</td><td>$12,000</td><td>$6,000</td><td>+$6,000</td></tr>
  <tr><td>WIP – Photonics</td><td>$35,000</td><td>$35,000</td><td>—</td></tr>
  <tr><td>Inventory – Finished Goods</td><td>$81,000</td><td>$74,000</td><td>+$7,000</td></tr>
  <tr><td>Intangible Assets – PDK License</td><td>$50,000</td><td>$50,000</td><td>—</td></tr>
  <tr><td>Accumulated Amortization</td><td>($4,167)</td><td>($2,778)</td><td>−$1,389</td></tr>
  <tr><td>Total Assets</td><td>$2,314,582</td><td>$2,442,088</td><td>−$127,506</td></tr>
  <tr><td>Liabilities</td><td></td><td></td><td></td></tr>
  <tr><td>Accounts Payable</td><td>$28,000</td><td>$22,000</td><td>+$6,000</td></tr>
  <tr><td>Accrued Liabilities</td><td>$15,000</td><td>$12,000</td><td>+$3,000</td></tr>
  <tr><td>Deferred Revenue</td><td>$9,167</td><td>$10,000</td><td>−$833</td></tr>
  <tr><td>Total Liabilities</td><td>$52,167</td><td>$44,000</td><td>+$8,167</td></tr>
  <tr><td>Equity</td><td></td><td></td><td></td></tr>
  <tr><td>Common Stock</td><td>$3,000,000</td><td>$3,000,000</td><td>—</td></tr>
  <tr><td>Retained Earnings</td><td>($737,585)</td><td>($601,912)</td><td>−$135,673</td></tr>
  <tr><td>Total Equity</td><td>$2,262,415</td><td>$2,398,088</td><td>−$135,673</td></tr>
  <tr><td>Total Liabilities &amp; Equity</td><td>$2,314,582</td><td>$2,442,088</td><td>−$127,506</td></tr>
</table>

### 2.3 Condensed Cash Flow Statement

<table>
  <tr><th>Line Item</th><th>Current Month</th><th>Prior Month</th><th>3-Month Total</th></tr>
  <tr><td>Operating Activities</td><td></td><td></td><td></td></tr>
  <tr><td>Net Income (Loss)</td><td>($129,617)</td><td>($125,417)</td><td>($379,584)</td></tr>
  <tr><td>Amortization — PDK License</td><td>$1,389</td><td>$1,389</td><td>$4,167</td></tr>
  <tr><td>Changes in Working Capital</td><td>($23,889)</td><td>($22,389)</td><td>($68,000)</td></tr>
  <tr><td>Net Cash from Operations</td><td>($152,117)</td><td>($146,417)</td><td>($443,417)</td></tr>
  <tr><td>Investing Activities</td><td></td><td></td><td></td></tr>
  <tr><td>Lab Equipment Purchases</td><td>$0</td><td>$0</td><td>($15,000)</td></tr>
  <tr><td>Net Cash from Investing</td><td>$0</td><td>$0</td><td>($15,000)</td></tr>
  <tr><td>Financing Activities</td><td></td><td></td><td></td></tr>
  <tr><td>Common Stock Issuance</td><td>$0</td><td>$0</td><td>$0</td></tr>
  <tr><td>Net Cash from Financing</td><td>$0</td><td>$0</td><td>$0</td></tr>
  <tr><td>Net Cash Change</td><td>($152,117)</td><td>($146,417)</td><td>($458,417)</td></tr>
  <tr><td>Beginning Cash</td><td>$2,206,866</td><td>$2,353,283</td><td>$2,500,000</td></tr>
  <tr><td>Ending Cash</td><td>$2,054,749</td><td>$2,206,866</td><td>$2,054,749</td></tr>
</table>

## Page 3: Operational KPIs & Variance Bridge

### 3.1 Semiconductor Operational Metrics

<table>
  <tr><th>Metric</th><th>Standard</th><th>Actual</th><th>Variance</th><th>Status</th><th>Corrective Action</th></tr>
  <tr><td>RISC-V64 SoC yield</td><td>95%</td><td>88%</td><td>−7 pp</td><td>🔴</td><td>CDC verification enhancement</td></tr>
  <tr><td>GPU yield</td><td>90%</td><td>78%</td><td>−12 pp</td><td>🔴</td><td>Stitch-aware layout constraints</td></tr>
  <tr><td>PTA photonics yield</td><td>85%</td><td>72%</td><td>−13 pp</td><td>🔴</td><td>AMF DOE run (Q1 2028)</td></tr>
  <tr><td>wafer.space slot price</td><td>$2,000</td><td>$8,000</td><td>+$6,000</td><td>🔴</td><td>Design freeze 4 weeks early</td></tr>
  <tr><td>GF/AMF photonics slot</td><td>$35,000</td><td>$42,000</td><td>+$7,000</td><td>🔴</td><td>AMF DRC rule integration</td></tr>
  <tr><td>Design engineer rate</td><td>$14,167/mo</td><td>$16,250/mo</td><td>+$2,083</td><td>🟡</td><td>Annual rate revision</td></tr>
  <tr><td>PDB BOM cost</td><td>$172.18</td><td>$200.80</td><td>+$28.62</td><td>🟡</td><td>Vendor renegotiation</td></tr>
  <tr><td>Forecast accuracy (EBITDA)</td><td>≥95%</td><td>98.0%</td><td>+3.0 pp</td><td>🟢</td><td>—</td></tr>
</table>

### 3.2 EBITDA Variance Bridge — Current Month

```plaintext
Prior Plan EBITDA:                    ($125,000)
─────────────────────────────────────────────────
Revenue variance:                      +$1,833 F
  ├── PTA sales beat:                  +$3,000 F
  ├── PDB sales in line:               $0
  └── Grant revenue in line:           $0

COGS variance:                         ($8,000) U
  ├── PTA yield miss:                  ($5,353) U
  ├── GPU yield miss:                  ($533) U
  ├── RISC-V64 yield miss:             ($148) U
  └── Board BOM variance:              ($1,966) U

R&D variance:                          ($3,250) U
  ├── Contract engineering:            ($3,250) U
  └── All other R&D in line:           $0

G&A variance:                          $0
─────────────────────────────────────────────────
Actual EBITDA:                        ($129,617)
Total Variance:                        ($4,617) U
```

### 3.3 Cash Runway Waterfall

```plaintext
Beginning Cash (M1):                   $2,500,000
─────────────────────────────────────────────────
Operating burn (M1–M3):                ($443,417)
Capital expenditures (M1–M3):          ($15,000)
Grant receipts (M1–M3):                +$62,500
Customer collections (M1–M3):          +$125,000
─────────────────────────────────────────────────
Current Cash (M3):                     $2,054,749

Projected burn (M4–M12):               ($1,025,366)
Projected photonics prepayment (M12):  ($35,000)
─────────────────────────────────────────────────
Projected Cash (M12):                  $994,383
Projected Runway (months):             14.9
```

### 3.4 Cash Runway Sensitivity

<table>
  <tr><th>Scenario</th><th>Monthly Burn</th><th>Runway</th><th>Trigger Point</th></tr>
  <tr><td>Base case</td><td>$150,000</td><td>14.9 months</td><td>—</td></tr>
  <tr><td>Photonics run accelerated to M9</td><td>$158,000</td><td>13.8 months</td><td>⚠️ Alert</td></tr>
  <tr><td>PTA yield drops to 65%</td><td>$165,000</td><td>12.4 months</td><td>⚠️ Alert</td></tr>
  <tr><td>Grant revenue delayed by 3 months</td><td>$175,000</td><td>11.2 months</td><td>🔴 Escalate</td></tr>
  <tr><td>Conservative scenario (all risks)</td><td>$195,000</td><td>9.8 months</td><td>🔴 Financing needed</td></tr>
</table>

## Page 4: Rolling Forecast & Scenario Outlook

### 4.1 12-Month Rolling Forecast Summary

<table>
  <tr><th>Metric</th><th>Q1 (Act)</th><th>Q2 (Fcst)</th><th>Q3 (Fcst)</th><th>Q4 (Fcst)</th><th>FY Total</th></tr>
  <tr><td>Revenue</td><td>$140,499</td><td>$206,499</td><td>$278,499</td><td>$568,750</td><td>$568,750</td></tr>
  <tr><td>Gross Profit</td><td>$116,499</td><td>$168,299</td><td>$228,699</td><td>$449,750</td><td>$449,750</td></tr>
  <tr><td>Gross Margin %</td><td>82.9%</td><td>81.5%</td><td>82.1%</td><td>79.1%</td><td>79.1%</td></tr>
  <tr><td>R&amp;D</td><td>$444,750</td><td>$444,750</td><td>$450,000</td><td>$1,777,500</td><td>$1,777,500</td></tr>
  <tr><td>EBITDA</td><td>($382,251)</td><td>($338,251)</td><td>($312,751)</td><td>($1,552,750)</td><td>($1,552,750)</td></tr>
  <tr><td>Cash Balance</td><td>$2,054,749</td><td>$1,716,498</td><td>$1,403,747</td><td>$994,383</td><td>$994,383</td></tr>
  <tr><td>Runway (months)</td><td>14.9</td><td>13.6</td><td>12.4</td><td>11.2</td><td>11.2</td></tr>
</table>

**Key insight:** The Q4 gross margin dip to 79.1% reflects the GF/AMF photonics prepayment ($35,000) hitting in a single month. The cash runway crosses below 12 months in Q4, which is the Board's alert threshold.

### 4.2 Scenario Comparison

<table>
  <tr><th>Scenario</th><th>Revenue</th><th>Gross Margin %</th><th>EBITDA</th><th>Cash Runway</th><th>Probability</th></tr>
  <tr><td>Conservative</td><td>$420,000</td><td>65.0%</td><td>($1,827,000)</td><td>9.8 months</td><td>25%</td></tr>
  <tr><td>Base</td><td>$568,750</td><td>79.1%</td><td>($1,552,750)</td><td>14.9 months</td><td>55%</td></tr>
  <tr><td>Aggressive</td><td>$750,000</td><td>84.0%</td><td>($1,050,000)</td><td>24.5 months</td><td>20%</td></tr>
  <tr><td>Weighted average</td><td>$561,875</td><td>77.1%</td><td>($1,536,963)</td><td>14.5 months</td><td>—</td></tr>
</table>

### 4.3 Key Forecast Assumptions

<table>
  <tr><th>Assumption</th><th>Base Case</th><th>Sensitivity</th><th>Impact if Wrong</th></tr>
  <tr><td>PTA yield</td><td>85%</td><td>±5 pp</td><td>±$2,500/month COGS</td></tr>
  <tr><td>GPU yield</td><td>90%</td><td>±5 pp</td><td>±$300/month COGS</td></tr>
  <tr><td>RISC-V64 yield</td><td>95%</td><td>±3 pp</td><td>±$100/month COGS</td></tr>
  <tr><td>Foundry slot price</td><td>$2,000</td><td>+$6,000 if late</td><td>+$18,000 one-time</td></tr>
  <tr><td>Photonics slot price</td><td>$35,000</td><td>+$7,000 if DRC</td><td>+$7,000 one-time</td></tr>
  <tr><td>Design engineer rate</td><td>$16,250/mo</td><td>+$2,083/mo</td><td>+$10,415/month</td></tr>
  <tr><td>Grant revenue</td><td>$250,000</td><td>−$100,000 if delayed</td><td>−$8,333/month</td></tr>
</table>

## Page 5: Risks, Opportunities & Board Asks

### 5.1 Top Risks

<table>
  <tr><th>#</th><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Mitigation</th><th>Owner</th></tr>
  <tr><td>1</td><td>PTA photonics yield remains below 85%</td><td>High</td><td>$5,353/month COGS</td><td>AMF DOE run Q1 2028 ($45,000)</td><td>CTO</td></tr>
  <tr><td>2</td><td>GPU reticle stitching yield below 90%</td><td>Medium</td><td>$533/month COGS</td><td>Stitch-aware layout constraints</td><td>Foundry Ops</td></tr>
  <tr><td>3</td><td>Foundry slot price escalation (missed early bird)</td><td>Medium</td><td>$18,000 one-time</td><td>Design freeze 4 weeks early</td><td>Program Mgmt</td></tr>
  <tr><td>4</td><td>Grant revenue delay</td><td>Medium</td><td>$8,333/month cash</td><td>Diversify grant pipeline</td><td>CFO</td></tr>
  <tr><td>5</td><td>Design engineer attrition</td><td>Low</td><td>$10,415/month</td><td>Competitive equity package</td><td>HR</td></tr>
  <tr><td>6</td><td>Cash runway below 12 months in Q4</td><td>Medium</td><td>Financing need</td><td>Monitor monthly; line of credit standby</td><td>CFO</td></tr>
</table>

### 5.2 Top Opportunities

<table>
  <tr><th>#</th><th>Opportunity</th><th>Upside</th><th>Investment</th><th>Timeline</th></tr>
  <tr><td>1</td><td>PTA yield improvement to 92%</td><td>+$3,500/month gross margin</td><td>$45,000 DOE</td><td>Q1 2028</td></tr>
  <tr><td>2</td><td>GPU yield improvement to 95%</td><td>+$400/month gross margin</td><td>$15,000 layout rework</td><td>Q2 2028</td></tr>
  <tr><td>3</td><td>Academic grant expansion</td><td>+$150,000 revenue</td><td>$10,000 proposal writing</td><td>Q1 2028</td></tr>
  <tr><td>4</td><td>PDB volume pricing (500+ units)</td><td>+$15/board margin</td><td>$5,000 vendor negotiation</td><td>Q2 2028</td></tr>
  <tr><td>5</td><td>Photonics IP licensing</td><td>+$250,000 revenue</td><td>$50,000 legal</td><td>Q3 2028</td></tr>
</table>

### 5.3 Board Asks

<table>
  <tr><th>#</th><th>Ask</th><th>Amount</th><th>Rationale</th><th>Decision Required By</th></tr>
  <tr><td>1</td><td>Approve AMF photonics DOE run</td><td>$45,000</td><td>Close PTA yield gap from 72% to 85%+</td><td>Q1 2028 board meeting</td></tr>
  <tr><td>2</td><td>Approve contract engineering extension</td><td>$44,000/quarter</td><td>Accelerate GPU design through stitching complexity</td><td>Q1 2028 board meeting</td></tr>
  <tr><td>3</td><td>Approve line of credit standby</td><td>$500,000</td><td>Maintain 12-month runway if grant revenue delayed</td><td>Q2 2028 board meeting</td></tr>
  <tr><td>4</td><td>Approve patent filing for PTA architecture</td><td>$25,000</td><td>Protect photonic tensor accelerator IP</td><td>Q2 2028 board meeting</td></tr>
  <tr><td>5</td><td>Ratify design freeze policy</td><td>Policy</td><td>Prevent $18,000 early-bird PPV</td><td>Immediate</td></tr>
</table>

## Page 6: Appendix — Detailed Variance Analysis

### 6.1 Variance Summary by Category

<table>
  <tr><th>Variance Category</th><th>Current Month</th><th>3-Month Total</th><th>FY Forecast</th><th>Root Cause</th><th>Action Owner</th></tr>
  <tr><td>Foundry PPV</td><td>$0</td><td>$18,000 U</td><td>$18,000 U</td><td>Missed early-bird deadline</td><td>Program Mgmt</td></tr>
  <tr><td>Photonics PPV</td><td>$0</td><td>$7,000 U</td><td>$7,000 U</td><td>DRC iterations</td><td>Photonics Eng</td></tr>
  <tr><td>Yield — RISC-V64</td><td>$148 U</td><td>$148 U</td><td>$148 U</td><td>CDC metastability</td><td>Design Eng</td></tr>
  <tr><td>Yield — GPU</td><td>$533 U</td><td>$533 U</td><td>$533 U</td><td>Stitch boundary overlay</td><td>Foundry Ops</td></tr>
  <tr><td>Yield — PTA</td><td>$5,353 U</td><td>$5,353 U</td><td>$5,353 U</td><td>Grating coupler loss</td><td>Photonics Eng</td></tr>
  <tr><td>Labor Rate</td><td>$10,415 U</td><td>$31,245 U</td><td>$124,980 U</td><td>AI talent premium</td><td>HR</td></tr>
  <tr><td>Labor Efficiency</td><td>$44,000 U</td><td>$132,000 U</td><td>$176,000 U</td><td>Contract engineers</td><td>Engineering</td></tr>
  <tr><td>BOM — PDB</td><td>$1,966 U</td><td>$5,898 U</td><td>$23,592 U</td><td>PCB stackup; PTA yield</td><td>Supply Chain</td></tr>
  <tr><td>Overhead Volume</td><td>$15,000 U</td><td>$15,000 U</td><td>$15,000 U</td><td>Deferred photonics run</td><td>Operations</td></tr>
  <tr><td>Overhead Spending</td><td>$3,900 U</td><td>$11,700 U</td><td>$46,800 U</td><td>Facility costs</td><td>Operations</td></tr>
  <tr><td>R&amp;D Budget</td><td>$3,250 U</td><td>$9,750 U</td><td>$39,000 U</td><td>Contract engineering</td><td>CTO</td></tr>
  <tr><td>Total</td><td>$84,565 U</td><td>$246,624 U</td><td>$454,405 U</td><td></td><td></td></tr>
</table>

### 6.2 Forecast Accuracy Trend

<table>
  <tr><th>Month</th><th>Forecast EBITDA</th><th>Actual EBITDA</th><th>Variance</th><th>Accuracy %</th><th>Root Cause</th></tr>
  <tr><td>M1</td><td>($130,000)</td><td>($133,217)</td><td>($3,217)</td><td>97.6%</td><td>PTA yield</td></tr>
  <tr><td>M2</td><td>($125,000)</td><td>($125,417)</td><td>($417)</td><td>99.7%</td><td>Minor</td></tr>
  <tr><td>M3</td><td>($128,000)</td><td>($129,617)</td><td>($1,617)</td><td>98.7%</td><td>Labor rate</td></tr>
  <tr><td>M4</td><td>($112,000)</td><td>($114,317)</td><td>($2,317)</td><td>98.0%</td><td>PTA yield</td></tr>
  <tr><td>M5</td><td>($105,000)</td><td>($106,517)</td><td>($1,517)</td><td>98.6%</td><td>BOM</td></tr>
  <tr><td>M6</td><td>($104,000)</td><td>($106,217)</td><td>($2,217)</td><td>97.9%</td><td>PTA yield</td></tr>
  <tr><td>Average</td><td></td><td></td><td>($1,884)</td><td>98.4%</td><td></td></tr>
</table>

**Target:** ≥95% EBITDA accuracy. **Status:** 🟢 Exceeding target.

### 6.3 Cash Runway Detail

<table>
  <tr><th>Month</th><th>Beginning Cash</th><th>Inflows</th><th>Outflows</th><th>Net Cash</th><th>Ending Cash</th><th>Runway</th></tr>
  <tr><td>M1</td><td>$2,500,000</td><td>$23,833</td><td>$170,550</td><td>($146,717)</td><td>$2,353,283</td><td>16.7</td></tr>
  <tr><td>M2</td><td>$2,353,283</td><td>$25,333</td><td>$171,750</td><td>($146,417)</td><td>$2,206,866</td><td>15.9</td></tr>
  <tr><td>M3</td><td>$2,206,866</td><td>$26,833</td><td>$178,950</td><td>($152,117)</td><td>$2,054,749</td><td>14.9</td></tr>
  <tr><td>M4</td><td>$2,054,749</td><td>$28,333</td><td>$174,150</td><td>($145,817)</td><td>$1,908,932</td><td>14.1</td></tr>
  <tr><td>M5</td><td>$1,908,932</td><td>$29,833</td><td>$175,350</td><td>($145,517)</td><td>$1,763,415</td><td>13.4</td></tr>
  <tr><td>M6</td><td>$1,763,415</td><td>$31,333</td><td>$182,550</td><td>($151,217)</td><td>$1,612,198</td><td>12.7</td></tr>
  <tr><td>M7</td><td>$1,612,198</td><td>$33,000</td><td>$185,000</td><td>($152,000)</td><td>$1,460,198</td><td>12.0</td></tr>
  <tr><td>M8</td><td>$1,460,198</td><td>$34,500</td><td>$188,000</td><td>($153,500)</td><td>$1,306,698</td><td>11.4</td></tr>
  <tr><td>M9</td><td>$1,306,698</td><td>$36,000</td><td>$190,000</td><td>($154,000)</td><td>$1,152,698</td><td>10.8</td></tr>
  <tr><td>M10</td><td>$1,152,698</td><td>$37,500</td><td>$192,000</td><td>($154,500)</td><td>$998,198</td><td>10.2</td></tr>
  <tr><td>M11</td><td>$998,198</td><td>$39,000</td><td>$195,000</td><td>($156,000)</td><td>$842,198</td><td>9.6</td></tr>
  <tr><td>M12</td><td>$842,198</td><td>$40,500</td><td>$242,000</td><td>($201,500)</td><td>$640,698</td><td>8.5</td></tr>
</table>

**Alert:** Cash runway crosses below 12 months in M7 and below 10 months in M11. The M12 photonics prepayment accelerates the decline. **Board action recommended:** Approve $500,000 line of credit standby at the Q2 2028 board meeting.

### 6.4 Grant Pipeline Detail

<table>
  <tr><th>Grant Proposal</th><th>Agency</th><th>Amount</th><th>Status</th><th>Expected Decision</th><th>Probability</th></tr>
  <tr><td>AI Chip Development for Academic Research</td><td>NSF</td><td>$150,000</td><td>Submitted</td><td>Q1 2028</td><td>60%</td></tr>
  <tr><td>Photonic Tensor Accelerator for ML</td><td>DARPA</td><td>$250,000</td><td>In preparation</td><td>Q2 2028</td><td>40%</td></tr>
  <tr><td>RISC-V64 SoC for University Labs</td><td>DoE</td><td>$100,000</td><td>Submitted</td><td>Q1 2028</td><td>70%</td></tr>
  <tr><td>Development Board for STEM Education</td><td>NSF</td><td>$75,000</td><td>Concept</td><td>Q3 2028</td><td>30%</td></tr>
  <tr><td>Total pipeline</td><td></td><td>$575,000</td><td></td><td></td><td>Weighted: $310,000</td></tr>
</table>

## Page 7: Board Resolution Template

### 7.1 Resolution for Photonics DOE Run

**RESOLVED**, that the Board of Directors hereby approves the expenditure of up to **$45,000** for a design-of-experiments (DOE) run with Advanced Micro Foundry (AMF) to characterize silicon photonics waveguide loss and grating coupler performance, with the objective of improving the Photonics Tensor Accelerator (PTA) yield from the current 72% to a target of 85% or higher.

**FURTHER RESOLVED**, that the Chief Technology Officer is authorized to execute the necessary technology agreement and MPW slot reservation with AMF, and that the Chief Financial Officer is authorized to disburse funds in accordance with the company's standard procurement policies.

### 7.2 Resolution for Line of Credit

**RESOLVED**, that the Board of Directors hereby authorizes the Chief Financial Officer to establish a **$500,000 revolving line of credit** with [Bank Name] to maintain a minimum cash runway of 12 months, on terms substantially similar to those presented to the Board.

**FURTHER RESOLVED**, that the CFO is authorized to execute all necessary loan documents and to draw upon the line of credit as needed to fund operations, provided that the aggregate principal amount outstanding shall not exceed $500,000 without further Board approval.

## Page 8: Board Meeting Agenda Template

<table>
  <tr><th>Time</th><th>Item</th><th>Presenter</th><th>Materials</th></tr>
  <tr><td>9:00–9:15</td><td>Call to order; approval of minutes</td><td>Board Chair</td><td>Minutes</td></tr>
  <tr><td>9:15–9:30</td><td>CEO update — strategy &amp; milestones</td><td>CEO</td><td>Strategy deck</td></tr>
  <tr><td>9:30–10:00</td><td>CFO financial summary</td><td>CFO</td><td>This document (Pages 1–3)</td></tr>
  <tr><td>10:00–10:30</td><td>Operational update — foundry &amp; photonics</td><td>CTO</td><td>Fab manifest; yield dashboard</td></tr>
  <tr><td>10:30–10:45</td><td>Break</td><td></td><td></td></tr>
  <tr><td>10:45–11:15</td><td>Rolling forecast &amp; scenario review</td><td>CFO</td><td>This document (Pages 4–6)</td></tr>
  <tr><td>11:15–11:45</td><td>Board discussion — risks &amp; opportunities</td><td>All</td><td>This document (Page 5)</td></tr>
  <tr><td>11:45–12:00</td><td>Board resolutions</td><td>Board Chair</td><td>This document (Page 7)</td></tr>
  <tr><td>12:00</td><td>Adjournment</td><td>Board Chair</td><td></td></tr>
</table>

## Summary: What Makes This Board-Ready

<table>
  <tr><th>Principle</th><th>How This Template Delivers</th></tr>
  <tr><td>One-page executive view</td><td>Page 1 gives the Board everything they need in 60 seconds</td></tr>
  <tr><td>Financial statements</td><td>Pages 2 provides condensed P&amp;L, balance sheet, and cash flow</td></tr>
  <tr><td>Operational KPIs</td><td>Page 3 links financial results to semiconductor yield metrics</td></tr>
  <tr><td>Forward-looking</td><td>Page 4 shows the 12-month rolling forecast and scenarios</td></tr>
  <tr><td>Risk &amp; opportunity</td><td>Page 5 frames the Board&#39;s fiduciary discussion</td></tr>
  <tr><td>Variance transparency</td><td>Page 6 provides detailed variance analysis for audit trail</td></tr>
  <tr><td>Actionable asks</td><td>Pages 5 and 7 give the Board specific resolutions to approve</td></tr>
  <tr><td>Time-bound</td><td>Page 8 provides a structured agenda with presenters and materials</td></tr>
</table>

---

This board-ready financial summary condenses everything we've built — the COA, the journal entry playbook, the variance analysis, and the rolling forecast — into a format that respects the Board's time while giving them the depth they need to govern effectively.

---

# Grant Compliance Reporting Template: Canadian Fabless Semiconductor Company

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Reporting Basis:** Canadian Granting Agencies (NRC IRAP, NSERC, CFI, FABrIC, Ontario CTI)  
**Reporting Cadence:** Per Grant Agreement (typically quarterly or annual)  
**Currency:** CAD  
**Basis:** Canadian GAAP (ASPE) or IFRS, as applicable

## Section 1: Canadian Grant Organizations Relevant to Your Business

Before presenting the reporting template itself, here is a summary of the Canadian grant organizations most relevant to your RISC-V64 SoC, GPU, PTA, and Development Board projects.

### 1.1 Federal Grant Organizations

<table>
  <tr><th>Organization</th><th>Program</th><th>Focus</th><th>Typical Award Range</th><th>Your Fit</th></tr>
  <tr><td>NRC IRAP</td><td>Industrial Research Assistance Program</td><td>SMEs advancing innovation, including photonics and semiconductors</td><td>$50,000–$500,000+</td><td>High — Direct fit for your AI chip R&amp;D and photonics work</td></tr>
  <tr><td>NSERC</td><td>Alliance Grants; International Joint Call (NSTC)</td><td>Academic-industry collaboration; semiconductors and AI</td><td>Up to $75,000/year (3 years)</td><td>High — If partnered with Canadian universities</td></tr>
  <tr><td>FABrIC (CMC Microsystems)</td><td>Challenge Grants; Fabrication Process Development</td><td>Semiconductor ecosystem; chip design and manufacturing</td><td>Up to $1M (40% of eligible costs)</td><td>Very High — Purpose-built for Canadian semiconductor companies</td></tr>
  <tr><td>Canada Foundation for Innovation (CFI)</td><td>Major Science Initiatives; Biosciences Research Infrastructure Fund</td><td>Research infrastructure; photonics, AI, semiconductors</td><td>$1M+ (for major projects)</td><td>Medium — For lab infrastructure if partnered with institutions</td></tr>
  <tr><td>Global Affairs Canada</td><td>Canada-UK Semiconductors Competition (via NRC IRAP)</td><td>International semiconductor R&amp;D collaboration</td><td>Up to £500,000 (UK); NRC IRAP funding (Canada)</td><td>Medium — If pursuing international photonics collaboration</td></tr>
</table>

### 1.2 Provincial Grant Organizations (Ontario)

<table>
  <tr><th>Organization</th><th>Program</th><th>Focus</th><th>Typical Award Range</th><th>Your Fit</th></tr>
  <tr><td>Ontario Government</td><td>Critical Technologies Initiative (CTI)</td><td>AI, semiconductors, photonics, quantum</td><td>Conditional grants</td><td>High — If you are located in Ontario and are a not-for-profit or partner with one</td></tr>
  <tr><td>Ontario Centre of Innovation</td><td>Various innovation programs</td><td>Technology commercialization</td><td>Variable</td><td>Medium — For commercialization-stage projects</td></tr>
</table>

### 1.3 Key Observations for Your Business

- **FABrIC** is the single most relevant program. It is a five-year, $217M project led by CMC Microsystems to secure Canada's future in semiconductors. It provides non-repayable grants to reimburse up to 40% of eligible project expenses, paid quarterly. Your RISC-V64 SoC, GPU, and PTA designs are directly eligible under the Fabrication Process Development and IoT Product Development tracks.
- **NRC IRAP** has a dedicated photonics focus and operates the Canadian Photonics Fabrication Centre (NRC-CPFC) in Ottawa. IRAP has designated a Photonics Industrial Technology Advisor as a key contact point. Your PTA photonic tensor accelerator is a direct fit. A recent IRAP agreement for metasurface foundry work (similar to your photonics fab model) was valued at $212,000 over 18 months.
- **NSERC's international joint call** with Taiwan's NSTC specifically targets semiconductors and AI, including compound semiconductors for AI technologies and AI technologies in MEMS sensors. Maximum funding is $225,000 over three years ($75,000/year). This requires an academic collaborator from Taiwan.
- **Ontario CTI** explicitly supports artificial intelligence and semiconductors as foundational technologies. However, eligibility is restricted to not-for-profit organizations. If you are a for-profit company, you would need to partner with an eligible delivery organization (e.g., a university or research institute).
- **CFI** reporting requires annual financial reports, performance and progress reports, and budget updates by **June 15** each year, with cumulative results as at March 31. Projects with CFI contributions under $1M complete a Project Progress Report annually for four years; projects over $1M report for five years.
- **NSERC** requires institutions to submit a **Statement of Account (Form 300)** annually for every grant, signed by a designated business officer, for the period ending March 31.

## Section 2: Grant Compliance Reporting Template

### 2.1 Cover Page and Certification

**GRANT COMPLIANCE REPORT**

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Granting Agency</td><td>[NRC IRAP / NSERC / FABrIC / CFI / Ontario CTI]</td></tr>
  <tr><td>Program Name</td><td>[Industrial Research Assistance Program / Alliance Grants / Challenge Grants / etc.]</td></tr>
  <tr><td>Grant Agreement Number</td><td>[Insert Agreement #]</td></tr>
  <tr><td>Recipient Legal Name</td><td>[Your Company Legal Name]</td></tr>
  <tr><td>Business Number (BN)</td><td>[CRA Business Number]</td></tr>
  <tr><td>Reporting Period</td><td>[Start Date] to [End Date]</td></tr>
  <tr><td>Report Type</td><td>☐ Interim (Quarterly) ☐ Interim (Annual) ☐ Final</td></tr>
  <tr><td>Report Due Date</td><td>[Date]</td></tr>
  <tr><td>Date Submitted</td><td>[Date]</td></tr>
</table>

**Certification:**

> I hereby certify that the information provided in this report is accurate and complete to the best of my knowledge. The expenditures reported herein conform to the terms and conditions of the grant agreement and were incurred for the purposes for which the grant was made. I understand that false or misleading information may result in the termination of funding and repayment of amounts received.

<table>
  <tr><th>Signature</th><th>Name</th><th>Title</th><th>Date</th></tr>
  <tr><td></td><td>[CFO or Authorized Officer]</td><td>Chief Financial Officer</td><td></td></tr>
</table>

### 2.2 Executive Summary

**Project Title:** AI-Driven RISC-V64 + GPU + Photonics Tensor Accelerator Development Board (PDB)

**Project Objectives (as per grant agreement):**

1. Design and fabricate a quad-core RISC-V64 SoC with integrated NPU using AI-assisted design methodology.
2. Design and fabricate a full GPU chip with reticle-stitched architecture.
3. Design and fabricate a photonics tensor accelerator (PTA) using silicon photonics.
4. Integrate all three chips onto a development board (PDB) for research organizations and academia.

**Progress Summary (narrative, 200–300 words):**

During the reporting period, the company achieved the following milestones:

- Completed AI-generated RTL for the RISC-V64 SoC and submitted GDS to [wafer.space](https://wafer.space/) for GF180MCU Run 3.
- Initiated reticle stitching design for the GPU chip, with 2 slots reserved on GF180MCU Run 3.
- Engaged GlobalFoundries/AMF for photonics MPW slot reservation; GDS submission is pending DRC waiver.
- Completed PCB NRE design for the PDB and placed the first BOM order.
- Hired 2 contract engineers to accelerate GPU design through reticle stitching complexity.

**Key Challenges:**

- PTA photonics yield was 72% actual vs. 85% standard, due to grating coupler insertion loss. A DOE run with AMF is planned for Q1 2028.
- Foundry slot pricing was $8,000/slot (standard) instead of $2,000/slot (early bird) due to a missed deadline. Corrective action: design freeze 4 weeks before slot purchase deadline.

### 2.3 Milestone and Deliverable Tracking

<table>
  <tr><th>#</th><th>Milestone / Deliverable</th><th>Due Date</th><th>Status</th><th>Completion %</th><th>Evidence / Notes</th></tr>
  <tr><td>1</td><td>RISC-V64 SoC RTL complete</td><td>Q1 2027</td><td>✅ Complete</td><td>100%</td><td>AI-generated RTL; verified via formal CDC checks</td></tr>
  <tr><td>2</td><td>RISC-V64 SoC GDS submission</td><td>Q4 2026</td><td>✅ Complete</td><td>100%</td><td>Submitted to wafer.space GF180MCU Run 3</td></tr>
  <tr><td>3</td><td>GPU RTL complete (stitched)</td><td>Q2 2027</td><td>🟡 In Progress</td><td>65%</td><td>Stitch boundary constraints under development</td></tr>
  <tr><td>4</td><td>GPU GDS submission</td><td>Q2 2027</td><td>🔴 Not Started</td><td>0%</td><td>Dependent on RTL completion</td></tr>
  <tr><td>5</td><td>PTA photonic layout complete</td><td>Q3 2027</td><td>🟡 In Progress</td><td>40%</td><td>AMF DRC iterations ongoing</td></tr>
  <tr><td>6</td><td>PTA GDS submission</td><td>Q4 2027</td><td>🔴 Not Started</td><td>0%</td><td>Awaiting DRC waiver</td></tr>
  <tr><td>7</td><td>PDB PCB design complete</td><td>Q3 2027</td><td>✅ Complete</td><td>100%</td><td>6-layer stackup; impedance-controlled</td></tr>
  <tr><td>8</td><td>First PDB prototype assembled</td><td>Q1 2028</td><td>🔴 Not Started</td><td>0%</td><td>Dependent on chip delivery</td></tr>
  <tr><td>9</td><td>PDB validation and testing</td><td>Q2 2028</td><td>🔴 Not Started</td><td>0%</td><td>—</td></tr>
  <tr><td>10</td><td>First PDB shipment to academia</td><td>Q3 2028</td><td>🔴 Not Started</td><td>0%</td><td>—</td></tr>
</table>

**Milestone payment request (if applicable):** ☐ Yes ☐ No

<table>
  <tr><th>Milestone #</th><th>Amount Requested</th><th>Cumulative to Date</th><th>Remaining</th></tr>
  <tr><td>1</td><td>$25,000</td><td>$25,000</td><td>$175,000</td></tr>
  <tr><td>2</td><td>$25,000</td><td>$50,000</td><td>$150,000</td></tr>
</table>

### 2.4 Financial Report — Statement of Account

**Grant Amount:** [TotalGrantAmount]∗∗AmountReceivedtoDate:∗∗[TotalGrantAmount]∗∗AmountReceivedtoDate:∗∗[Amount]  
**Amount Expended to Date:** [Amount]∗∗UnspentBalance:∗∗[Amount]∗∗UnspentBalance:∗∗[Amount]  
**Reporting Period Expenditures:** $[Amount]

**Expenditure Detail by Category:**

<table>
  <tr><th>Eligible Cost Category</th><th>Budget (Grant Agreement)</th><th>Expended This Period</th><th>Cumulative Expended</th><th>Remaining Budget</th><th>% of Budget Used</th></tr>
  <tr><td>Personnel</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Design engineering labor</td><td>$600,000</td><td>$125,250</td><td>$375,750</td><td>$224,250</td><td>62.6%</td></tr>
  <tr><td>Contract engineering</td><td>$176,000</td><td>$44,000</td><td>$132,000</td><td>$44,000</td><td>75.0%</td></tr>
  <tr><td>Subtotal Personnel</td><td>$776,000</td><td>$169,250</td><td>$507,750</td><td>$268,250</td><td>65.4%</td></tr>
  <tr><td>Direct Materials</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Foundry — wafer.space</td><td>$24,000</td><td>$6,000</td><td>$18,000</td><td>$6,000</td><td>75.0%</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$35,000</td><td>$0</td><td>$0</td><td>$35,000</td><td>0.0%</td></tr>
  <tr><td>Assembly &amp; Test</td><td>$25,000</td><td>$3,000</td><td>$9,000</td><td>$16,000</td><td>36.0%</td></tr>
  <tr><td>Board BOM</td><td>$35,000</td><td>$4,200</td><td>$12,600</td><td>$22,400</td><td>36.0%</td></tr>
  <tr><td>Subtotal Direct Materials</td><td>$119,000</td><td>$13,200</td><td>$39,600</td><td>$79,400</td><td>33.3%</td></tr>
  <tr><td>Equipment</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Lab equipment</td><td>$15,000</td><td>$0</td><td>$15,000</td><td>$0</td><td>100.0%</td></tr>
  <tr><td>Subtotal Equipment</td><td>$15,000</td><td>$0</td><td>$15,000</td><td>$0</td><td>100.0%</td></tr>
  <tr><td>Other Direct Costs</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>EDA software &amp; IP</td><td>$152,000</td><td>$12,500</td><td>$37,500</td><td>$114,500</td><td>24.7%</td></tr>
  <tr><td>Mask &amp; reticle costs</td><td>$22,500</td><td>$7,500</td><td>$7,500</td><td>$15,000</td><td>33.3%</td></tr>
  <tr><td>Prototype &amp; test</td><td>$100,000</td><td>$8,000</td><td>$24,000</td><td>$76,000</td><td>24.0%</td></tr>
  <tr><td>PCB development</td><td>$15,000</td><td>$0</td><td>$0</td><td>$15,000</td><td>0.0%</td></tr>
  <tr><td>Subtotal Other Direct Costs</td><td>$289,500</td><td>$28,000</td><td>$69,000</td><td>$220,500</td><td>23.8%</td></tr>
  <tr><td>Total Eligible Expenditures</td><td>$1,199,500</td><td>$210,450</td><td>$631,350</td><td>$568,150</td><td>52.6%</td></tr>
</table>

**Grant Claim Calculation:**

<table>
  <tr><th>Calculation</th><th>Amount</th></tr>
  <tr><td>Total eligible expenditures (cumulative)</td><td>$631,350</td></tr>
  <tr><td>Reimbursement rate (per agreement)</td><td>40%</td></tr>
  <tr><td>Eligible claim amount</td><td>$252,540</td></tr>
  <tr><td>Less: prior claims paid</td><td>($100,000)</td></tr>
  <tr><td>Current claim amount</td><td>$152,540</td></tr>
</table>

**Supporting Documentation Attached:**

- ☐ Payroll registers for personnel costs
- ☐ Invoices from [wafer.space](https://wafer.space/) for foundry costs
- ☐ Invoices from GF/AMF for photonics costs
- ☐ Invoices from PCB vendor for NRE costs
- ☐ EDA software subscription receipts
- ☐ Bank statements showing expenditures
- ☐ General ledger extract for grant-related accounts

### 2.5 Personnel Report

<table>
  <tr><th>Role</th><th>Name</th><th>FTE % on Grant</th><th>Hours This Period</th><th>Grant-Funded Salary</th><th>Verification</th></tr>
  <tr><td>Design Engineer (RISC-V64)</td><td>[Name]</td><td>100%</td><td>160</td><td>$16,250</td><td>Timesheet on file</td></tr>
  <tr><td>Design Engineer (GPU)</td><td>[Name]</td><td>100%</td><td>160</td><td>$16,250</td><td>Timesheet on file</td></tr>
  <tr><td>AI/ML Engineer</td><td>[Name]</td><td>100%</td><td>160</td><td>$16,250</td><td>Timesheet on file</td></tr>
  <tr><td>Photonics Engineer</td><td>[Name]</td><td>100%</td><td>160</td><td>$16,250</td><td>Timesheet on file</td></tr>
  <tr><td>Contract Engineer (GPU)</td><td>[Contractor]</td><td>100%</td><td>160</td><td>$22,000</td><td>Invoice on file</td></tr>
  <tr><td>Contract Engineer (GPU)</td><td>[Contractor]</td><td>100%</td><td>160</td><td>$22,000</td><td>Invoice on file</td></tr>
  <tr><td>Total Personnel</td><td></td><td></td><td>960 hours</td><td>$109,000</td><td></td></tr>
</table>

**Note:** Personnel costs are supported by contemporaneous timesheets that identify the grant project and the hours worked. For NSERC grants, Form 300 requires institutional certification of salaries.

### 2.6 Intellectual Property Report

<table>
  <tr><th>IP Item</th><th>Type</th><th>Status</th><th>Jurisdiction</th><th>Filing Date</th><th>Grant Agency Rights</th></tr>
  <tr><td>RISC-V64 SoC NPU architecture</td><td>Patent (provisional)</td><td>Filed</td><td>Canada</td><td>Q1 2027</td><td>Agency may have rights per agreement</td></tr>
  <tr><td>GPU reticle stitching method</td><td>Trade secret</td><td>Internal</td><td>N/A</td><td>N/A</td><td>Agency notified</td></tr>
  <tr><td>PTA photonic tensor architecture</td><td>Patent (provisional)</td><td>In preparation</td><td>Canada, US</td><td>Q2 2027</td><td>Agency may have rights per agreement</td></tr>
  <tr><td>PDB development board design</td><td>Copyright</td><td>Registered</td><td>Canada</td><td>Q3 2027</td><td>Agency may have rights per agreement</td></tr>
</table>

**IP Disclosure:** ☐ No new IP created this period ☐ New IP created (details above)

**Publication and Dissemination:**

<table>
  <tr><th>Publication / Presentation</th><th>Venue</th><th>Date</th><th>Grant Acknowledged</th></tr>
  <tr><td>&quot;AI-Driven RISC-V64 SoC for Research Applications&quot;</td><td>[Conference Name]</td><td>Q2 2027</td><td>☐ Yes ☐ No</td></tr>
  <tr><td>&quot;Photonics Tensor Accelerator for ML Workloads&quot;</td><td>[Journal Name]</td><td>Q3 2027</td><td>☐ Yes ☐ No</td></tr>
</table>

### 2.7 Compliance Certifications

<table>
  <tr><th>Compliance Item</th><th>Status</th><th>Notes</th></tr>
  <tr><td>Eligible costs only</td><td>✅ Confirmed</td><td>All expenditures comply with grant agreement</td></tr>
  <tr><td>Arms-length transactions</td><td>✅ Confirmed</td><td>All related-party transactions disclosed</td></tr>
  <tr><td>Procurement policy</td><td>✅ Confirmed</td><td>Competitive bidding followed for all purchases &gt; $10,000</td></tr>
  <tr><td>Conflict of interest</td><td>✅ Confirmed</td><td>No undisclosed conflicts</td></tr>
  <tr><td>Environmental compliance</td><td>✅ Confirmed</td><td>No environmental liabilities</td></tr>
  <tr><td>Human rights compliance</td><td>✅ Confirmed</td><td>No forced labor in supply chain</td></tr>
  <tr><td>Accessibility (AODA)</td><td>✅ Confirmed</td><td>Compliant with Ontario accessibility requirements</td></tr>
  <tr><td>Official languages</td><td>✅ Confirmed</td><td>Communications available in both official languages</td></tr>
</table>

### 2.8 Variance Explanation (Grant Budget vs. Actual)

<table>
  <tr><th>Variance Item</th><th>Budget</th><th>Actual</th><th>Variance</th><th>Explanation</th></tr>
  <tr><td>Foundry slot price</td><td>$2,000/slot</td><td>$8,000/slot</td><td>$6,000 U</td><td>Missed early-bird deadline; design freeze policy implemented</td></tr>
  <tr><td>Photonics slot cost</td><td>$35,000</td><td>$42,000</td><td>$7,000 U</td><td>Additional DRC iterations (5 vs. 3 standard)</td></tr>
  <tr><td>PTA yield</td><td>85%</td><td>72%</td><td>−13 pp</td><td>Grating coupler insertion loss; DOE run planned</td></tr>
  <tr><td>Design engineer rate</td><td>$14,167/mo</td><td>$16,250/mo</td><td>$2,083 U</td><td>AI talent market premium</td></tr>
  <tr><td>PCB NRE</td><td>$15,000</td><td>$28,000</td><td>$13,000 U</td><td>6-layer stackup upgrade for impedance control</td></tr>
</table>

**Corrective actions taken:**

- Design freeze milestone established 4 weeks before slot purchase deadline.
- AMF DRC rule deck integrated into AI photonic design tool.
- DOE run with AMF approved for Q1 2028 ($45,000).
- Annual standard rate revision scheduled for Q1 2028.

### 2.9 Cash Flow and Liquidity Statement

<table>
  <tr><th>Metric</th><th>Amount</th></tr>
  <tr><td>Grant funds received to date</td><td>$[Amount]</td></tr>
  <tr><td>Grant funds expended to date</td><td>$[Amount]</td></tr>
  <tr><td>Unspent grant funds</td><td>$[Amount]</td></tr>
  <tr><td>Company cash balance</td><td>$2,054,749</td></tr>
  <tr><td>Monthly burn rate</td><td>$152,117</td></tr>
  <tr><td>Cash runway (months)</td><td>14.9</td></tr>
</table>

**Liquidity Certification:** The company has sufficient working capital to complete the grant-funded project and meet its obligations under the grant agreement.

### 2.10 Attachments Checklist

<table>
  <tr><th>Attachment</th><th>Included</th><th>Notes</th></tr>
  <tr><td>Financial statements (audited or reviewed)</td><td>☐</td><td>Required for CTI; optional for others</td></tr>
  <tr><td>Payroll registers</td><td>☐</td><td>For personnel cost verification</td></tr>
  <tr><td>Supplier invoices</td><td>☐</td><td>wafer.space, GF/AMF, PCB vendor, EDA vendors</td></tr>
  <tr><td>Timesheets</td><td>☐</td><td>For all grant-funded personnel</td></tr>
  <tr><td>Bank statements</td><td>☐</td><td>Showing grant expenditures</td></tr>
  <tr><td>General ledger extract</td><td>☐</td><td>Grant-related accounts</td></tr>
  <tr><td>IP disclosure forms</td><td>☐</td><td>If applicable</td></tr>
  <tr><td>Publication acknowledgements</td><td>☐</td><td>If applicable</td></tr>
  <tr><td>Certificate of compliance</td><td>☐</td><td>Signed by authorized officer</td></tr>
</table>

## Section 3: Agency-Specific Reporting Requirements

### 3.1 NRC IRAP Reporting Requirements

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Reporting frequency</td><td>Per agreement; typically quarterly for active projects</td></tr>
  <tr><td>Financial reporting</td><td>Statement of Account with supporting invoices</td></tr>
  <tr><td>Technical reporting</td><td>Progress reports against milestones</td></tr>
  <tr><td>Final report</td><td>Within 3 months of project completion</td></tr>
  <tr><td>Audit</td><td>NRC IRAP reserves the right to audit</td></tr>
  <tr><td>Key contact</td><td>Industrial Technology Advisor (ITA) assigned to your file</td></tr>
</table>

**IRAP-specific note:** IRAP has a dedicated Photonics ITA and operates the Canadian Photonics Fabrication Centre (NRC-CPFC) in Ottawa. Your PTA project should leverage this relationship for both funding and technical support.

### 3.2 NSERC Reporting Requirements

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Statement of Account</td><td>Form 300 (Grants in Aid of Research)</td></tr>
  <tr><td>Filing deadline</td><td>Annually for period ending March 31</td></tr>
  <tr><td>Signature</td><td>Designated business officer of the institution</td></tr>
  <tr><td>System</td><td>Financial Data Submission and Reconciliation (FDSR) system</td></tr>
  <tr><td>Final report</td><td>Within 3 months of grant end (or extension)</td></tr>
</table>

**NSERC-specific note:** NSERC grants are held by the institution (university), not the company. If you are partnering with a Canadian university on the NSERC-NSTC semiconductor/AI call, the university submits Form 300 on behalf of the grant.

### 3.3 FABrIC Reporting Requirements

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Reimbursement model</td><td>Up to 40% of eligible project expenses</td></tr>
  <tr><td>Payment frequency</td><td>Quarterly reimbursements</td></tr>
  <tr><td>Maximum funding</td><td>Up to $1M per project</td></tr>
  <tr><td>Reporting</td><td>Per Challenge Grant agreement</td></tr>
  <tr><td>Eligible costs</td><td>Fabrication, personnel, equipment, materials</td></tr>
</table>

**FABrIC-specific note:** FABrIC operates Challenges in two tracks: **Fabrication Process Development** and **IoT Product Development**. Your PDB development board is a direct fit for the IoT Product Development track, while your AI chip designs fit the Fabrication Process Development track.

### 3.4 CFI Reporting Requirements

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Financial report</td><td>Annually by June 15</td></tr>
  <tr><td>Performance and progress report</td><td>Annually by June 15</td></tr>
  <tr><td>Budget update</td><td>Annually by June 15</td></tr>
  <tr><td>Reporting period</td><td>April 1 to March 31</td></tr>
  <tr><td>System</td><td>CFI Contribution Management System (SGCF)</td></tr>
  <tr><td>PPR duration</td><td>4 years (≤$1M) or 5 years (&gt;$1M)</td></tr>
</table>

**CFI-specific note:** CFI funding is typically for research infrastructure (buildings, equipment, labs). If you are partnering with a university or research institute to access CFI-funded photonics fabrication equipment, the institution is the reporting entity, not your company.

### 3.5 Ontario CTI Reporting Requirements

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Eligibility</td><td>Not-for-profit organizations only</td></tr>
  <tr><td>Financial statements</td><td>Audited or accountant-reviewed for 3 fiscal years</td></tr>
  <tr><td>Reporting</td><td>Per conditional grant agreement</td></tr>
  <tr><td>AI requirement</td><td>Projects must include AI initiatives</td></tr>
  <tr><td>Pillars</td><td>Must address 3+ of: Infrastructure, Commercialization, Adoption, Talent</td></tr>
</table>

**CTI-specific note:** As a for-profit company, you are not directly eligible for CTI funding. However, you can partner with an eligible delivery organization (e.g., a university, college, or not-for-profit research institute) that applies for CTI funding and includes your project as a deliverable. CTI funding supports projects between April 1, 2026 and March 31, 2029.

## Section 4: Grant Compliance Calendar

<table>
  <tr><th>Month</th><th>Activity</th><th>Agency</th><th>Owner</th></tr>
  <tr><td>January</td><td>IRAP Q4 progress report</td><td>NRC IRAP</td><td>CFO</td></tr>
  <tr><td>February</td><td>NSERC Form 300 preparation</td><td>NSERC</td><td>University partner</td></tr>
  <tr><td>March</td><td>Year-end financial close for grant accounts</td><td>All</td><td>Accounting</td></tr>
  <tr><td>April</td><td>CFI annual financial report preparation</td><td>CFI</td><td>CFO</td></tr>
  <tr><td>May</td><td>NSERC Form 300 submission (for period ending March 31)</td><td>NSERC</td><td>University partner</td></tr>
  <tr><td>June</td><td>CFI annual reports due (June 15)</td><td>CFI</td><td>CFO</td></tr>
  <tr><td>July</td><td>IRAP Q1 progress report</td><td>NRC IRAP</td><td>CFO</td></tr>
  <tr><td>August</td><td>FABrIC Challenge Grant EOI (if applicable)</td><td>FABrIC</td><td>CTO</td></tr>
  <tr><td>September</td><td>FABrIC full proposal (by invitation)</td><td>FABrIC</td><td>CTO</td></tr>
  <tr><td>October</td><td>IRAP Q2 progress report</td><td>NRC IRAP</td><td>CFO</td></tr>
  <tr><td>November</td><td>Grant audit preparation</td><td>All</td><td>Accounting</td></tr>
  <tr><td>December</td><td>Annual grant compliance review</td><td>All</td><td>CFO</td></tr>
</table>

## Section 5: Key Compliance Policies

<table>
  <tr><th>Policy</th><th>Specification</th></tr>
  <tr><td>Eligible cost documentation</td><td>Every grant-funded expenditure must be supported by an invoice, timesheet, or payroll record</td></tr>
  <tr><td>Segregation of duties</td><td>Grant expenditures are approved by the CFO and reviewed by the CTO</td></tr>
  <tr><td>Timesheet policy</td><td>All personnel charging to grants must complete contemporaneous timesheets identifying the grant and project</td></tr>
  <tr><td>Procurement policy</td><td>Competitive bidding required for all purchases exceeding $10,000</td></tr>
  <tr><td>Related-party disclosure</td><td>All related-party transactions must be disclosed to the granting agency</td></tr>
  <tr><td>IP disclosure</td><td>New IP must be disclosed to the granting agency within 30 days of creation</td></tr>
  <tr><td>Publication acknowledgement</td><td>All publications must acknowledge grant support</td></tr>
  <tr><td>Record retention</td><td>Grant records must be retained for 7 years after grant completion</td></tr>
  <tr><td>Audit cooperation</td><td>The company will cooperate fully with any granting agency audit</td></tr>
</table>

---

This grant compliance reporting gives us a complete framework for managing reporting obligations across Canada's major semiconductor and AI funding programs. The key insight is that **FABrIC** and **NRC IRAP** are your two highest-priority funding sources, and both require quarterly financial reporting with detailed supporting documentation.

---

# Monthly Close Checklist: Canadian Fabless Semiconductor Company

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Close Calendar:** Business days from month-end  
**Target Close:** Day 8 (preliminary), Day 10 (final)  
**Currency:** CAD  
**Reporting Basis:** Canadian GAAP (ASPE) or IFRS

---

## Close Calendar Overview

<table>
  <tr><th>Phase</th><th>Days</th><th>Focus</th><th>Output</th></tr>
  <tr><td>Phase 1: Pre-Close</td><td>Day −3 to Day 0</td><td>Cut-off preparation, accrual gathering</td><td>Readiness confirmation</td></tr>
  <tr><td>Phase 2: Transaction Processing</td><td>Day 1–2</td><td>AP/AR, payroll, bank reconciliations</td><td>Sub-ledgers closed</td></tr>
  <tr><td>Phase 3: Inventory &amp; WIP</td><td>Day 2–3</td><td>Foundry/photonics WIP reconciliation, yield variance</td><td>Inventory valuation</td></tr>
  <tr><td>Phase 4: Accruals &amp; Provisions</td><td>Day 3–4</td><td>Month-end accruals, prepayments, amortization</td><td>Accrual entries posted</td></tr>
  <tr><td>Phase 5: Grant Accounting</td><td>Day 4–5</td><td>Grant revenue recognition, compliance tracking</td><td>Grant reports</td></tr>
  <tr><td>Phase 6: Variance Analysis</td><td>Day 4–5</td><td>PPV, yield, labor, BOM variances</td><td>Variance report</td></tr>
  <tr><td>Phase 7: Reconciliations</td><td>Day 5–6</td><td>Balance sheet reconciliations, intercompany</td><td>Reconciled TB</td></tr>
  <tr><td>Phase 8: Financial Statements</td><td>Day 6–7</td><td>P&amp;L, BS, CF, supporting schedules</td><td>Draft financials</td></tr>
  <tr><td>Phase 9: Rolling Forecast Update</td><td>Day 7–8</td><td>Actuals roll-in, driver updates, rollover</td><td>Updated forecast</td></tr>
  <tr><td>Phase 10: Review &amp; Reporting</td><td>Day 8–10</td><td>CFO review, board package, grant reports</td><td>Final close package</td></tr>
</table>

---

## Phase 1: Pre-Close (Day −3 to Day 0)

### 1.1 Cut-Off Communication

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>1.1.1</td><td>Distribute close calendar and cut-off memo to all departments</td><td>Controller</td><td>Day −3</td><td>—</td><td>☐</td></tr>
  <tr><td>1.1.2</td><td>Confirm AP cut-off: all invoices for month must be received by Day 1</td><td>AP Clerk</td><td>Day −3</td><td>—</td><td>☐</td></tr>
  <tr><td>1.1.3</td><td>Confirm AR cut-off: all shipping documents for month must be submitted by Day 1</td><td>AR Clerk</td><td>Day −3</td><td>—</td><td>☐</td></tr>
  <tr><td>1.1.4</td><td>Confirm payroll cut-off: all timesheets submitted by Day 0</td><td>Payroll Admin</td><td>Day −3</td><td>—</td><td>☐</td></tr>
  <tr><td>1.1.5</td><td>Confirm grant timesheets submitted by Day 0</td><td>Grant Admin</td><td>Day −3</td><td>—</td><td>☐</td></tr>
  <tr><td>1.1.6</td><td>Notify foundry partners (wafer.space, GF/AMF) of month-end close and request WIP statements</td><td>Controller</td><td>Day −3</td><td>—</td><td>☐</td></tr>
</table>

### 1.2 Pre-Close Data Gathering

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>1.2.1</td><td>Obtain wafer.space WIP statement for month-end</td><td>Foundry Ops</td><td>Day 0</td><td>wafer.space portal</td><td>☐</td></tr>
  <tr><td>1.2.2</td><td>Obtain GF/AMF photonics WIP statement for month-end</td><td>Photonics Eng</td><td>Day 0</td><td>GF/AMF portal</td><td>☐</td></tr>
  <tr><td>1.2.3</td><td>Obtain OSAT (assembly &amp; test) WIP statement</td><td>Supply Chain</td><td>Day 0</td><td>OSAT portal</td><td>☐</td></tr>
  <tr><td>1.2.4</td><td>Obtain bank statements for all operating accounts</td><td>Treasury</td><td>Day 0</td><td>Bank portal</td><td>☐</td></tr>
  <tr><td>1.2.5</td><td>Obtain credit card statements</td><td>AP Clerk</td><td>Day 0</td><td>Card portal</td><td>☐</td></tr>
  <tr><td>1.2.6</td><td>Obtain payroll register for the month</td><td>Payroll Admin</td><td>Day 0</td><td>Payroll system</td><td>☐</td></tr>
  <tr><td>1.2.7</td><td>Obtain grant expenditure detail from all departments</td><td>Grant Admin</td><td>Day 0</td><td>Department heads</td><td>☐</td></tr>
  <tr><td>1.2.8</td><td>Obtain EDA software usage reports (for allocation)</td><td>IT</td><td>Day 0</td><td>Vendor portal</td><td>☐</td></tr>
</table>

### 1.3 Pre-Close Review

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>1.3.1</td><td>Review open purchase orders for goods/services received but not invoiced</td><td>Procurement</td><td>Day 0</td><td>PO system</td><td>☐</td></tr>
  <tr><td>1.3.2</td><td>Review open sales orders for goods shipped but not invoiced</td><td>Sales Ops</td><td>Day 0</td><td>Order system</td><td>☐</td></tr>
  <tr><td>1.3.3</td><td>Review prior month&#39;s close checklist for carry-forward items</td><td>Controller</td><td>Day 0</td><td>Prior checklist</td><td>☐</td></tr>
  <tr><td>1.3.4</td><td>Confirm no unscheduled foundry runs or photonics submissions occurred</td><td>Foundry Ops</td><td>Day 0</td><td>Fab manifest</td><td>☐</td></tr>
</table>

---

## Phase 2: Transaction Processing (Day 1–2)

### 2.1 Accounts Payable

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>2.1.1</td><td>Enter all vendor invoices received through cut-off</td><td>AP Clerk</td><td>Day 1</td><td>Invoice inbox</td><td>☐</td></tr>
  <tr><td>2.1.2</td><td>Match foundry invoices to purchase orders and receiving reports (3-way match)</td><td>AP Clerk</td><td>Day 1</td><td>PO system</td><td>☐</td></tr>
  <tr><td>2.1.3</td><td>Match photonics invoices to purchase orders and DRC confirmations</td><td>AP Clerk</td><td>Day 1</td><td>PO system</td><td>☐</td></tr>
  <tr><td>2.1.4</td><td>Match PCB vendor invoices to NRE purchase orders</td><td>AP Clerk</td><td>Day 1</td><td>PO system</td><td>☐</td></tr>
  <tr><td>2.1.5</td><td>Match EDA software invoices to subscription agreements</td><td>AP Clerk</td><td>Day 1</td><td>Vendor contracts</td><td>☐</td></tr>
  <tr><td>2.1.6</td><td>Process expense report reimbursements</td><td>AP Clerk</td><td>Day 1</td><td>Expense system</td><td>☐</td></tr>
  <tr><td>2.1.7</td><td>Run AP aging report and review for unusual items</td><td>AP Clerk</td><td>Day 2</td><td>AP sub-ledger</td><td>☐</td></tr>
  <tr><td>2.1.8</td><td>Accrue for goods/services received but not invoiced (GR/IR accrual)</td><td>Controller</td><td>Day 2</td><td>Open PO review</td><td>☐</td></tr>
</table>

**Journal Entry — GR/IR Accrual:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$X,XXX</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$X,XXX</td></tr>
</table>

### 2.2 Accounts Receivable

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>2.2.1</td><td>Generate invoices for all PDB development boards shipped in month</td><td>AR Clerk</td><td>Day 1</td><td>Shipping docs</td><td>☐</td></tr>
  <tr><td>2.2.2</td><td>Generate invoices for all chip sales (RISC-V64, GPU, PTA) shipped in month</td><td>AR Clerk</td><td>Day 1</td><td>Shipping docs</td><td>☐</td></tr>
  <tr><td>2.2.3</td><td>Generate grant milestone invoices (if applicable)</td><td>Grant Admin</td><td>Day 1</td><td>Milestone evidence</td><td>☐</td></tr>
  <tr><td>2.2.4</td><td>Apply cash receipts to open invoices</td><td>AR Clerk</td><td>Day 1</td><td>Bank statements</td><td>☐</td></tr>
  <tr><td>2.2.5</td><td>Run AR aging report and review for collectability</td><td>AR Clerk</td><td>Day 2</td><td>AR sub-ledger</td><td>☐</td></tr>
  <tr><td>2.2.6</td><td>Assess allowance for doubtful accounts (academic customers)</td><td>Controller</td><td>Day 2</td><td>Aging report</td><td>☐</td></tr>
</table>

**Journal Entry — Revenue Recognition (Board Sale):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable</td><td>$5,000</td><td></td></tr>
  <tr><td>4000 · Revenue – Board Sales</td><td></td><td>$5,000</td></tr>
</table>

**Journal Entry — COGS (Board Sale):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>5000 · COGS – Development Boards</td><td>$1,620</td><td></td></tr>
  <tr><td>1430 · Inventory – Finished Goods (PDB)</td><td></td><td>$1,620</td></tr>
</table>

### 2.3 Payroll

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>2.3.1</td><td>Process monthly payroll for all employees</td><td>Payroll Admin</td><td>Day 1</td><td>Payroll system</td><td>☐</td></tr>
  <tr><td>2.3.2</td><td>Process contract engineer invoices</td><td>AP Clerk</td><td>Day 1</td><td>Contractor invoices</td><td>☐</td></tr>
  <tr><td>2.3.3</td><td>Allocate payroll costs to R&amp;D and G&amp;A accounts</td><td>Controller</td><td>Day 2</td><td>Payroll register</td><td>☐</td></tr>
  <tr><td>2.3.4</td><td>Allocate grant-funded salaries to grant projects</td><td>Grant Admin</td><td>Day 2</td><td>Timesheets</td><td>☐</td></tr>
  <tr><td>2.3.5</td><td>Accrue for unpaid vacation and employer payroll taxes</td><td>Payroll Admin</td><td>Day 2</td><td>Payroll system</td><td>☐</td></tr>
  <tr><td>2.3.6</td><td>Reconcile payroll tax remittances (CPP, EI, income tax)</td><td>Payroll Admin</td><td>Day 2</td><td>CRA portal</td><td>☐</td></tr>
</table>

**Journal Entry — Payroll Allocation:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$125,250</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$125,250</td></tr>
</table>

**Journal Entry — Vacation Accrual:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$12,000</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$12,000</td></tr>
</table>

### 2.4 Bank Reconciliations

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>2.4.1</td><td>Reconcile operating bank account</td><td>Treasury</td><td>Day 2</td><td>Bank statement</td><td>☐</td></tr>
  <tr><td>2.4.2</td><td>Reconcile payroll bank account</td><td>Treasury</td><td>Day 2</td><td>Bank statement</td><td>☐</td></tr>
  <tr><td>2.4.3</td><td>Reconcile USD account (for wafer.space/GF payments)</td><td>Treasury</td><td>Day 2</td><td>Bank statement</td><td>☐</td></tr>
  <tr><td>2.4.4</td><td>Reconcile credit card accounts</td><td>AP Clerk</td><td>Day 2</td><td>Card statements</td><td>☐</td></tr>
  <tr><td>2.4.5</td><td>Review outstanding checks and deposits in transit</td><td>Treasury</td><td>Day 2</td><td>Bank reconciliation</td><td>☐</td></tr>
  <tr><td>2.4.6</td><td>Record foreign exchange gains/losses on USD transactions</td><td>Controller</td><td>Day 2</td><td>Bank reconciliation</td><td>☐</td></tr>
</table>

**Journal Entry — Foreign Exchange (USD Foundry Invoice):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$8,200</td><td></td></tr>
  <tr><td>1000 · Cash – Operating (CAD equivalent)</td><td></td><td>$8,000</td></tr>
  <tr><td>7100 · Foreign Exchange Loss</td><td>$200</td><td></td></tr>
</table>

---

## Phase 3: Inventory & WIP (Day 2–3)

### 3.1 Foundry WIP Reconciliation ([wafer.space](https://wafer.space/))

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>3.1.1</td><td>Obtain wafer.space WIP statement showing die count by lot and stage</td><td>Foundry Ops</td><td>Day 0</td><td>wafer.space portal</td><td>☐</td></tr>
  <tr><td>3.1.2</td><td>Reconcile wafer.space WIP statement to internal WIP ledger</td><td>Controller</td><td>Day 2</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>3.1.3</td><td>Investigate and resolve any discrepancies (die count, stage, cost)</td><td>Foundry Ops</td><td>Day 3</td><td>Reconciliation</td><td>☐</td></tr>
  <tr><td>3.1.4</td><td>Calculate RISC-V64 SoC yield variance (standard vs. actual)</td><td>Foundry Ops</td><td>Day 3</td><td>Die count</td><td>☐</td></tr>
  <tr><td>3.1.5</td><td>Calculate GPU yield variance (standard vs. actual)</td><td>Foundry Ops</td><td>Day 3</td><td>Die count</td><td>☐</td></tr>
  <tr><td>3.1.6</td><td>Post WIP reclassification entries for completed lots</td><td>Controller</td><td>Day 3</td><td>Yield calculation</td><td>☐</td></tr>
</table>

**Journal Entry — WIP Reclassification (Completed Lot):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td>$2,000</td><td></td></tr>
  <tr><td>5120 · Yield Variance – RISC-V64 SoC</td><td>$148 U</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$2,000</td></tr>
</table>

### 3.2 Photonics WIP Reconciliation (GF/AMF)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>3.2.1</td><td>Obtain GF/AMF WIP statement showing photonic chip count by lot</td><td>Photonics Eng</td><td>Day 0</td><td>GF/AMF portal</td><td>☐</td></tr>
  <tr><td>3.2.2</td><td>Reconcile GF/AMF WIP statement to internal WIP ledger</td><td>Controller</td><td>Day 2</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>3.2.3</td><td>Investigate and resolve any discrepancies (chip count, DRC iterations)</td><td>Photonics Eng</td><td>Day 3</td><td>Reconciliation</td><td>☐</td></tr>
  <tr><td>3.2.4</td><td>Calculate PTA yield variance (standard vs. actual)</td><td>Photonics Eng</td><td>Day 3</td><td>Chip count</td><td>☐</td></tr>
  <tr><td>3.2.5</td><td>Post WIP reclassification entries for completed photonics lots</td><td>Controller</td><td>Day 3</td><td>Yield calculation</td><td>☐</td></tr>
</table>

**Journal Entry — PTA WIP Reclassification:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1420 · Inventory – Finished Goods (PTA)</td><td>$35,000</td><td></td></tr>
  <tr><td>5140 · Yield Variance – PTA</td><td>$5,353 U</td><td></td></tr>
  <tr><td>1310 · WIP – Photonics (GF/AMF)</td><td></td><td>$35,000</td></tr>
</table>

### 3.3 Assembly & Test WIP Reconciliation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>3.3.1</td><td>Obtain OSAT WIP statement for chips in assembly/test</td><td>Supply Chain</td><td>Day 0</td><td>OSAT portal</td><td>☐</td></tr>
  <tr><td>3.3.2</td><td>Reconcile OSAT WIP to internal WIP ledger</td><td>Controller</td><td>Day 2</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>3.3.3</td><td>Calculate assembly labor and overhead variances</td><td>Supply Chain</td><td>Day 3</td><td>OSAT invoice</td><td>☐</td></tr>
  <tr><td>3.3.4</td><td>Post WIP reclassification for completed assemblies</td><td>Controller</td><td>Day 3</td><td>Reconciliation</td><td>☐</td></tr>
</table>

### 3.4 Finished Goods Inventory

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>3.4.1</td><td>Update perpetual inventory records for all chip receipts</td><td>Supply Chain</td><td>Day 2</td><td>Receiving reports</td><td>☐</td></tr>
  <tr><td>3.4.2</td><td>Update perpetual inventory records for PDB board assembly</td><td>Supply Chain</td><td>Day 2</td><td>Production reports</td><td>☐</td></tr>
  <tr><td>3.4.3</td><td>Calculate BOM variance for PDB boards produced</td><td>Supply Chain</td><td>Day 3</td><td>BOM standard vs. actual</td><td>☐</td></tr>
  <tr><td>3.4.4</td><td>Review inventory for obsolescence and slow-moving items</td><td>Controller</td><td>Day 3</td><td>Inventory aging</td><td>☐</td></tr>
  <tr><td>3.4.5</td><td>Post inventory write-down entries (if required)</td><td>Controller</td><td>Day 3</td><td>Obsolescence review</td><td>☐</td></tr>
</table>

**Journal Entry — Inventory Write-Down:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>8000 · Inventory Write-Down – Obsolete Chips</td><td>$2,500</td><td></td></tr>
  <tr><td>1400 · Inventory – Finished Goods (RISC-V64 SoC)</td><td></td><td>$1,000</td></tr>
  <tr><td>1410 · Inventory – Finished Goods (GPU)</td><td></td><td>$1,500</td></tr>
</table>

### 3.5 Cost of Goods Sold

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>3.5.1</td><td>Calculate COGS for PDB boards sold during month</td><td>Controller</td><td>Day 3</td><td>Sales records</td><td>☐</td></tr>
  <tr><td>3.5.2</td><td>Calculate COGS for chip sales (RISC-V64, GPU, PTA)</td><td>Controller</td><td>Day 3</td><td>Sales records</td><td>☐</td></tr>
  <tr><td>3.5.3</td><td>Post COGS journal entries</td><td>Controller</td><td>Day 3</td><td>Calculations</td><td>☐</td></tr>
  <tr><td>3.5.4</td><td>Reconcile COGS to inventory movement</td><td>Controller</td><td>Day 3</td><td>Inventory records</td><td>☐</td></tr>
</table>

---

## Phase 4: Accruals & Provisions (Day 3–4)

### 4.1 Month-End Accruals

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>4.1.1</td><td>Accrue for foundry fabrication progress not yet invoiced</td><td>Controller</td><td>Day 3</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>4.1.2</td><td>Accrue for photonics fabrication progress not yet invoiced</td><td>Controller</td><td>Day 3</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>4.1.3</td><td>Accrue for OSAT assembly/test services rendered but not invoiced</td><td>Controller</td><td>Day 3</td><td>OSAT statement</td><td>☐</td></tr>
  <tr><td>4.1.4</td><td>Accrue for EDA software usage not yet invoiced</td><td>Controller</td><td>Day 3</td><td>Usage report</td><td>☐</td></tr>
  <tr><td>4.1.5</td><td>Accrue for legal and IP fees</td><td>Controller</td><td>Day 3</td><td>Legal estimates</td><td>☐</td></tr>
  <tr><td>4.1.6</td><td>Accrue for facilities costs (rent, utilities)</td><td>Controller</td><td>Day 3</td><td>Lease agreements</td><td>☐</td></tr>
  <tr><td>4.1.7</td><td>Accrue for contract engineer services</td><td>Controller</td><td>Day 3</td><td>Contractor estimates</td><td>☐</td></tr>
  <tr><td>4.1.8</td><td>Reverse prior month&#39;s accruals</td><td>Controller</td><td>Day 3</td><td>Prior accrual JE</td><td>☐</td></tr>
</table>

**Journal Entry — Foundry Accrual:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$5,000</td><td></td></tr>
  <tr><td>2100 · Accrued Liabilities</td><td></td><td>$5,000</td></tr>
</table>

**Journal Entry — Reverse Prior Accrual:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2100 · Accrued Liabilities</td><td>$4,500</td><td></td></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td></td><td>$4,500</td></tr>
</table>

### 4.2 Prepayments & Amortization

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>4.2.1</td><td>Amortize prepaid foundry costs (as fabrication progresses)</td><td>Controller</td><td>Day 3</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>4.2.2</td><td>Amortize prepaid photonics costs (as fabrication progresses)</td><td>Controller</td><td>Day 3</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>4.2.3</td><td>Amortize PDK license (monthly)</td><td>Controller</td><td>Day 3</td><td>Amortization schedule</td><td>☐</td></tr>
  <tr><td>4.2.4</td><td>Amortize prepaid insurance</td><td>Controller</td><td>Day 3</td><td>Insurance policy</td><td>☐</td></tr>
  <tr><td>4.2.5</td><td>Amortize prepaid rent</td><td>Controller</td><td>Day 3</td><td>Lease agreement</td><td>☐</td></tr>
  <tr><td>4.2.6</td><td>Record depreciation on lab equipment</td><td>Controller</td><td>Day 3</td><td>Fixed asset register</td><td>☐</td></tr>
</table>

**Journal Entry — PDK License Amortization:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>7000 · Amortization – PDK License</td><td>$1,389</td><td></td></tr>
  <tr><td>1510 · Accumulated Amortization – PDK License</td><td></td><td>$1,389</td></tr>
</table>

**Journal Entry — Lab Equipment Depreciation:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6030 · R&amp;D – Prototype &amp; Test Engineering</td><td>$2,000</td><td></td></tr>
  <tr><td>1510 · Accumulated Depreciation – Lab Equipment</td><td></td><td>$2,000</td></tr>
</table>

---

## Phase 5: Grant Accounting (Day 4–5)

### 5.1 Grant Revenue Recognition

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>5.1.1</td><td>Review grant milestone completion for revenue recognition</td><td>Grant Admin</td><td>Day 4</td><td>Milestone tracker</td><td>☐</td></tr>
  <tr><td>5.1.2</td><td>Calculate grant revenue to recognize (milestone-based or cost-based)</td><td>Controller</td><td>Day 4</td><td>Grant agreement</td><td>☐</td></tr>
  <tr><td>5.1.3</td><td>Post grant revenue recognition entries</td><td>Controller</td><td>Day 4</td><td>Calculation</td><td>☐</td></tr>
  <tr><td>5.1.4</td><td>Reconcile deferred revenue balance to grant agreements</td><td>Controller</td><td>Day 4</td><td>Grant agreements</td><td>☐</td></tr>
</table>

**Journal Entry — Grant Revenue Recognition:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2200 · Deferred Revenue</td><td>$20,833</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td></td><td>$20,833</td></tr>
</table>

### 5.2 Grant Expenditure Tracking

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>5.2.1</td><td>Compile grant-funded expenditures by category (personnel, materials, equipment)</td><td>Grant Admin</td><td>Day 4</td><td>GL extract</td><td>☐</td></tr>
  <tr><td>5.2.2</td><td>Reconcile grant expenditures to grant budget</td><td>Grant Admin</td><td>Day 4</td><td>Budget vs. actual</td><td>☐</td></tr>
  <tr><td>5.2.3</td><td>Verify all personnel costs are supported by timesheets</td><td>Grant Admin</td><td>Day 4</td><td>Timesheets</td><td>☐</td></tr>
  <tr><td>5.2.4</td><td>Verify all supplier invoices are eligible costs</td><td>Grant Admin</td><td>Day 4</td><td>Grant agreement</td><td>☐</td></tr>
  <tr><td>5.2.5</td><td>Prepare grant claim calculation (reimbursement rate × eligible costs)</td><td>Controller</td><td>Day 4</td><td>Expenditure detail</td><td>☐</td></tr>
  <tr><td>5.2.6</td><td>Prepare grant compliance report (if due this month)</td><td>Grant Admin</td><td>Day 5</td><td>This checklist</td><td>☐</td></tr>
</table>

### 5.3 Grant-Specific Close Tasks

<table>
  <tr><th>Grant Agency</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>NRC IRAP</td><td>Prepare quarterly progress report (if quarter-end)</td><td>Grant Admin</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>NRC IRAP</td><td>Prepare Statement of Account with supporting invoices</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>NSERC</td><td>Prepare Form 300 input for university partner</td><td>Grant Admin</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>FABrIC</td><td>Prepare quarterly reimbursement claim</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>FABrIC</td><td>Prepare milestone progress report</td><td>Grant Admin</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>CFI</td><td>Prepare annual financial report (if June 15 deadline)</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>Ontario CTI</td><td>Prepare partner reporting package (if applicable)</td><td>Grant Admin</td><td>Day 5</td><td>☐</td></tr>
</table>

---

## Phase 6: Variance Analysis (Day 4–5)

### 6.1 Variance Calculations

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>6.1.1</td><td>Calculate Purchase Price Variance (PPV) on foundry invoices</td><td>Procurement</td><td>Day 4</td><td>AP sub-ledger</td><td>☐</td></tr>
  <tr><td>6.1.2</td><td>Calculate PPV on photonics invoices</td><td>Procurement</td><td>Day 4</td><td>AP sub-ledger</td><td>☐</td></tr>
  <tr><td>6.1.3</td><td>Calculate yield variance for RISC-V64 SoC</td><td>Foundry Ops</td><td>Day 4</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>6.1.4</td><td>Calculate yield variance for GPU</td><td>Foundry Ops</td><td>Day 4</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>6.1.5</td><td>Calculate yield variance for PTA</td><td>Photonics Eng</td><td>Day 4</td><td>WIP statement</td><td>☐</td></tr>
  <tr><td>6.1.6</td><td>Calculate labor rate variance</td><td>HR / Payroll</td><td>Day 4</td><td>Payroll register</td><td>☐</td></tr>
  <tr><td>6.1.7</td><td>Calculate labor efficiency variance</td><td>Engineering</td><td>Day 4</td><td>Timesheets</td><td>☐</td></tr>
  <tr><td>6.1.8</td><td>Calculate BOM variance for PDB boards</td><td>Supply Chain</td><td>Day 4</td><td>BOM records</td><td>☐</td></tr>
  <tr><td>6.1.9</td><td>Calculate overhead volume variance</td><td>Operations</td><td>Day 4</td><td>Production records</td><td>☐</td></tr>
  <tr><td>6.1.10</td><td>Calculate overhead spending variance</td><td>Operations</td><td>Day 4</td><td>GL extract</td><td>☐</td></tr>
  <tr><td>6.1.11</td><td>Calculate R&amp;D budget variance by category</td><td>FP&amp;A</td><td>Day 4</td><td>GL extract</td><td>☐</td></tr>
</table>

### 6.2 Variance Investigation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>6.2.1</td><td>Investigate PPV &gt; $5,000 or &gt; 10%</td><td>Procurement</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.2.2</td><td>Investigate yield variance &gt; 3 percentage points</td><td>Foundry Ops</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.2.3</td><td>Investigate labor rate variance &gt; 5%</td><td>HR</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.2.4</td><td>Investigate BOM variance &gt; $10 per board</td><td>Supply Chain</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.2.5</td><td>Investigate R&amp;D budget variance &gt; 15% in any category</td><td>FP&amp;A</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.2.6</td><td>Document root cause and corrective action for each material variance</td><td>Variance owners</td><td>Day 5</td><td>Investigation</td><td>☐</td></tr>
</table>

### 6.3 Variance Journal Entries

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Dependency</th><th>Done</th></tr>
  <tr><td>6.3.1</td><td>Post PPV journal entries</td><td>Controller</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.3.2</td><td>Post yield variance journal entries</td><td>Controller</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.3.3</td><td>Post labor variance journal entries</td><td>Controller</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.3.4</td><td>Post BOM variance journal entries</td><td>Controller</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
  <tr><td>6.3.5</td><td>Post overhead variance journal entries</td><td>Controller</td><td>Day 5</td><td>Variance calc</td><td>☐</td></tr>
</table>

**Journal Entry — PPV Recognition:**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1300 · WIP – Foundry (wafer.space)</td><td>$24,000</td><td></td></tr>
  <tr><td>5100 · PPV – Foundry Slot Price</td><td>$18,000 U</td><td></td></tr>
  <tr><td>1200 · Prepaid Foundry Costs</td><td></td><td>$6,000</td></tr>
</table>

---

## Phase 7: Reconciliations (Day 5–6)

### 7.1 Balance Sheet Reconciliations

<table>
  <tr><th>#</th><th>Account</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>7.1.1</td><td>Cash – Operating</td><td>Treasury</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.2</td><td>Accounts Receivable (aging to GL)</td><td>AR Clerk</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.3</td><td>Prepaid Foundry Costs – wafer.space</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.4</td><td>Prepaid Photonics Costs – GF/AMF</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.5</td><td>WIP – Foundry (wafer.space)</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.6</td><td>WIP – Photonics (GF/AMF)</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.7</td><td>WIP – Assembly &amp; Test</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.8</td><td>Inventory – Finished Goods (all four categories)</td><td>Supply Chain</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.9</td><td>Intangible Assets – PDK License</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.10</td><td>Accounts Payable (aging to GL)</td><td>AP Clerk</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.11</td><td>Accrued Liabilities</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.12</td><td>Deferred Revenue</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.13</td><td>Common Stock</td><td>Controller</td><td>Day 5</td><td>☐</td></tr>
  <tr><td>7.1.14</td><td>Retained Earnings</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
</table>

### 7.2 Intercompany and Related-Party Reconciliation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>7.2.1</td><td>Reconcile any intercompany transactions (if multiple entities)</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.2.2</td><td>Confirm no related-party transactions require disclosure</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.2.3</td><td>Reconcile grant funds held in separate bank account (if required)</td><td>Treasury</td><td>Day 6</td><td>☐</td></tr>
</table>

### 7.3 Trial Balance Review

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>7.3.1</td><td>Run trial balance and review for unusual balances</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.3.2</td><td>Verify debits = credits</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.3.3</td><td>Review all accounts with abnormal balances (e.g., negative inventory)</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.3.4</td><td>Review large or unusual journal entries</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>7.3.5</td><td>Lock the period in the accounting system</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
</table>

---

## Phase 8: Financial Statements (Day 6–7)

### 8.1 Statement Preparation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>8.1.1</td><td>Prepare condensed income statement</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>8.1.2</td><td>Prepare condensed balance sheet</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>8.1.3</td><td>Prepare condensed cash flow statement</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>8.1.4</td><td>Prepare supporting schedules (COGS detail, R&amp;D detail)</td><td>Controller</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>8.1.5</td><td>Prepare variance analysis report</td><td>FP&amp;A</td><td>Day 6</td><td>☐</td></tr>
  <tr><td>8.1.6</td><td>Prepare grant expenditure report</td><td>Grant Admin</td><td>Day 6</td><td>☐</td></tr>
</table>

### 8.2 Financial Review

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>8.2.1</td><td>CFO review of draft financials</td><td>CFO</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>8.2.2</td><td>CTO review of R&amp;D expenditures and grant compliance</td><td>CTO</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>8.2.3</td><td>CEO review of key metrics and variances</td><td>CEO</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>8.2.4</td><td>Incorporate review comments and finalize financials</td><td>Controller</td><td>Day 7</td><td>☐</td></tr>
</table>

---

## Phase 9: Rolling Forecast Update (Day 7–8)

### 9.1 Actuals Roll-In

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>9.1.1</td><td>Pull actuals into rolling forecast (revenue, COGS, R&amp;D, cash)</td><td>FP&amp;A</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.1.2</td><td>Calculate variances vs. prior forecast for all driver lines</td><td>FP&amp;A</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.1.3</td><td>Update variance-to-forecast bridge</td><td>FP&amp;A</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.1.4</td><td>Update forecast accuracy tracking</td><td>FP&amp;A</td><td>Day 7</td><td>☐</td></tr>
</table>

### 9.2 Driver Updates

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>9.2.1</td><td>Update revenue drivers (PDB units, chip sales, grant pipeline)</td><td>Sales / Grant Admin</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.2.2</td><td>Update foundry cost drivers (slot prices, yield assumptions)</td><td>Foundry Ops</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.2.3</td><td>Update photonics cost drivers (slot cost, yield assumptions)</td><td>Photonics Eng</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.2.4</td><td>Update R&amp;D drivers (headcount, EDA seats, prototype hours)</td><td>Engineering</td><td>Day 7</td><td>☐</td></tr>
  <tr><td>9.2.5</td><td>Update G&amp;A drivers (legal, facilities)</td><td>Operations</td><td>Day 7</td><td>☐</td></tr>
</table>

### 9.3 Rollover and Scenario Refresh

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>9.3.1</td><td>Roll the forecast window forward (drop oldest month, add new month)</td><td>FP&amp;A</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>9.3.2</td><td>Re-weight scenarios based on latest yield data and grant pipeline</td><td>FP&amp;A</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>9.3.3</td><td>Update cash runway projection</td><td>Treasury</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>9.3.4</td><td>Alert CFO if runway falls below 12 months</td><td>Treasury</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>9.3.5</td><td>Refresh rolling forecast dashboard</td><td>FP&amp;A</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>9.3.6</td><td>Archive prior forecast version for trend analysis</td><td>FP&amp;A</td><td>Day 8</td><td>☐</td></tr>
</table>

---

## Phase 10: Review & Reporting (Day 8–10)

### 10.1 Board Reporting Package

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>10.1.1</td><td>Prepare board-ready financial summary (Pages 1–3)</td><td>CFO</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.1.2</td><td>Prepare operational KPI dashboard</td><td>CTO</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.1.3</td><td>Prepare variance bridge for board</td><td>FP&amp;A</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.1.4</td><td>Prepare risk and opportunity summary</td><td>CFO</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.1.5</td><td>Prepare board resolutions (if needed)</td><td>CFO</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.1.6</td><td>Distribute board package (7 days before board meeting)</td><td>Executive Assistant</td><td>Day 9</td><td>☐</td></tr>
</table>

### 10.2 Grant Reporting Package

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>10.2.1</td><td>Prepare grant compliance report (if due this month)</td><td>Grant Admin</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.2.2</td><td>Attach supporting documentation (invoices, timesheets, payroll)</td><td>Grant Admin</td><td>Day 8</td><td>☐</td></tr>
  <tr><td>10.2.3</td><td>Obtain CFO certification signature</td><td>CFO</td><td>Day 9</td><td>☐</td></tr>
  <tr><td>10.2.4</td><td>Submit grant report to agency (if due)</td><td>Grant Admin</td><td>Day 10</td><td>☐</td></tr>
  <tr><td>10.2.5</td><td>File grant report copy in compliance folder</td><td>Grant Admin</td><td>Day 10</td><td>☐</td></tr>
</table>

### 10.3 Final Close Package

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Due</th><th>Done</th></tr>
  <tr><td>10.3.1</td><td>Assemble final close package (financials, variance report, grant report)</td><td>Controller</td><td>Day 9</td><td>☐</td></tr>
  <tr><td>10.3.2</td><td>Distribute close package to CFO, CEO, CTO</td><td>Controller</td><td>Day 9</td><td>☐</td></tr>
  <tr><td>10.3.3</td><td>File close package in accounting archive</td><td>Controller</td><td>Day 10</td><td>☐</td></tr>
  <tr><td>10.3.4</td><td>Update close checklist for next month (carry-forward items)</td><td>Controller</td><td>Day 10</td><td>☐</td></tr>
  <tr><td>10.3.5</td><td>Conduct close retrospective (what went well, what to improve)</td><td>Controller</td><td>Day 10</td><td>☐</td></tr>
  <tr><td>10.3.6</td><td>Update close calendar for next month</td><td>Controller</td><td>Day 10</td><td>☐</td></tr>
</table>

---

## Monthly Close Dashboard

<table>
  <tr><th>Phase</th><th>Target Day</th><th>Actual Day</th><th>Status</th><th>Blockers</th></tr>
  <tr><td>Pre-Close</td><td>Day −3 to 0</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Transaction Processing</td><td>Day 1–2</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Inventory &amp; WIP</td><td>Day 2–3</td><td></td><td>🟡</td><td>Awaiting wafer.space WIP statement</td></tr>
  <tr><td>Accruals &amp; Provisions</td><td>Day 3–4</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Grant Accounting</td><td>Day 4–5</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Variance Analysis</td><td>Day 4–5</td><td></td><td>🟡</td><td>PTA yield investigation ongoing</td></tr>
  <tr><td>Reconciliations</td><td>Day 5–6</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Financial Statements</td><td>Day 6–7</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Rolling Forecast Update</td><td>Day 7–8</td><td></td><td>🟢</td><td></td></tr>
  <tr><td>Review &amp; Reporting</td><td>Day 8–10</td><td></td><td>🟢</td><td></td></tr>
</table>

---

## Close Checklist Summary by Role

### Controller

- Review open POs and GR/IR accruals
- Post all month-end journal entries
- Reconcile WIP – Foundry and WIP – Photonics
- Calculate and post yield variances
- Prepare financial statements
- Lock the period
- Assemble final close package

### AP Clerk

- Enter all vendor invoices
- Perform 3-way match on foundry and photonics invoices
- Process expense reports
- Reconcile credit card accounts
- Run AP aging report

### AR Clerk

- Generate invoices for all shipments
- Apply cash receipts
- Run AR aging report
- Assess allowance for doubtful accounts

### Payroll Admin

- Process monthly payroll
- Accrue vacation and payroll taxes
- Reconcile payroll tax remittances
- Submit grant timesheets

### Foundry Ops

- Obtain [wafer.space](https://wafer.space/) WIP statement
- Calculate RISC-V64 and GPU yield variances
- Investigate yield discrepancies
- Update foundry cost drivers

### Photonics Eng

- Obtain GF/AMF WIP statement
- Calculate PTA yield variance
- Investigate photonics yield discrepancies
- Update photonics cost drivers

### Supply Chain

- Obtain OSAT WIP statement
- Update perpetual inventory records
- Calculate BOM variance
- Review inventory for obsolescence

### Grant Admin

- Compile grant-funded expenditures
- Reconcile grant expenditures to budget
- Verify timesheets and eligible costs
- Prepare grant compliance report
- Submit grant report to agency

### FP&A

- Calculate R&D budget variance
- Update rolling forecast with actuals
- Update driver assumptions
- Roll forecast window forward
- Prepare variance-to-forecast bridge

### Treasury

- Reconcile all bank accounts
- Record foreign exchange gains/losses
- Update cash runway projection
- Alert CFO if runway below 12 months

### CFO

- Review draft financials
- Review variance analysis
- Certify grant compliance report
- Prepare board-ready financial summary
- Conduct close retrospective

---

## Close Calendar — Quick Reference

<table>
  <tr><th>Day</th><th>Key Activities</th><th>Owner</th></tr>
  <tr><td>Day −3</td><td>Distribute close calendar; confirm cut-off</td><td>Controller</td></tr>
  <tr><td>Day 0</td><td>Obtain WIP statements; bank statements; payroll register</td><td>All</td></tr>
  <tr><td>Day 1</td><td>Enter AP invoices; generate AR invoices; process payroll</td><td>AP/AR/Payroll</td></tr>
  <tr><td>Day 2</td><td>Bank reconciliations; WIP reconciliation; payroll allocation</td><td>Treasury/Controller</td></tr>
  <tr><td>Day 3</td><td>Yield variance calc; accruals; amortization; inventory review</td><td>Controller/Foundry Ops</td></tr>
  <tr><td>Day 4</td><td>Grant revenue recognition; grant expenditure tracking; variance calcs</td><td>Grant Admin/FP&amp;A</td></tr>
  <tr><td>Day 5</td><td>Post variance JEs; balance sheet reconciliations; grant report prep</td><td>Controller</td></tr>
  <tr><td>Day 6</td><td>Trial balance review; financial statement prep; lock period</td><td>Controller</td></tr>
  <tr><td>Day 7</td><td>CFO/CTO/CEO review; rolling forecast actuals roll-in</td><td>CFO/FP&amp;A</td></tr>
  <tr><td>Day 8</td><td>Forecast rollover; scenario refresh; board package prep</td><td>FP&amp;A/CFO</td></tr>
  <tr><td>Day 9</td><td>Distribute board package; submit grant reports</td><td>Executive Assistant/Grant Admin</td></tr>
  <tr><td>Day 10</td><td>Final close package; retrospective; update next month&#39;s calendar</td><td>Controller</td></tr>
</table>

---

This monthly close checklist gives you a complete, role-based operational framework for closing your books in 8–10 business days. The key insight for your business is that **WIP reconciliation with [wafer.space](https://wafer.space/) and GF/AMF** is the critical path item — if those statements are delayed, the entire close slips. I recommend establishing a standing calendar invitation with your foundry partners to deliver WIP statements by Day 0 each month.

---

# Grant Application Tracker: Canadian Fabless Semiconductor Company

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Tracker Owner:** CFO / Grant Administrator  
**Update Cadence:** Weekly review; monthly reconciliation to rolling forecast  
**Currency:** CAD

## Section 1: Grant Opportunity Master Tracker

This is your master view. Every grant opportunity — active, prospective, or closed — lives here. Update the **Status** and **Next Action** columns weekly.

<table>
  <tr><th>#</th><th>Grant Program</th><th>Agency</th><th>Type</th><th>Max Funding</th><th>Reimbursement</th><th>Key Deadlines</th><th>Status</th><th>Owner</th><th>Next Action</th><th>Probability</th><th>Weighted Value</th></tr>
  <tr><td>1</td><td>NRC IRAP</td><td>NRC</td><td>Non-repayable contribution</td><td>No published max</td><td>Varies (typically 50–80%)</td><td>Continuous intake</td><td>🟡 In Discussion</td><td>CFO</td><td>Schedule ITA meeting; prepare project pitch</td><td>75%</td><td>$150,000</td></tr>
  <tr><td>2</td><td>FABrIC – Fabrication Process Development</td><td>CMC Microsystems / ISED</td><td>Non-repayable grant</td><td>$1M (up to $1.5M exceptional)</td><td>40%</td><td>EOI: Sep 8, 2026; Full: Oct 27, 2026 (Round 3)</td><td>🟢 Preparing EOI</td><td>CTO</td><td>Complete Blackbaud account; draft EOI</td><td>60%</td><td>$400,000</td></tr>
  <tr><td>3</td><td>FABrIC – IoT Product Development</td><td>CMC Microsystems / ISED</td><td>Non-repayable grant</td><td>$1M</td><td>37%</td><td>EOI: Sep 8, 2026; Full: Oct 27, 2026</td><td>🟢 Preparing EOI</td><td>CFO</td><td>Align PDB project with IoT track; draft EOI</td><td>60%</td><td>$185,000</td></tr>
  <tr><td>4</td><td>NSERC-NSTC (Taiwan) Semiconductor &amp; AI</td><td>NSERC</td><td>Academic collaboration grant</td><td>$75,000/year (3 years)</td><td>Up to $225,000 total</td><td>LOI: Mar 25, 2026 (closed); Full: Jul 30, 2026</td><td>🔴 Missed LOI</td><td>Grant Admin</td><td>Monitor next call (2027)</td><td>0% (this cycle)</td><td>—</td></tr>
  <tr><td>5</td><td>NSERC Alliance Advantage</td><td>NSERC</td><td>Collaborative research grant</td><td>Varies</td><td>Cost-sharing</td><td>Continuous intake</td><td>🟡 Identifying academic partner</td><td>CTO</td><td>Contact Canadian universities with photonics programs</td><td>50%</td><td>$75,000</td></tr>
  <tr><td>6</td><td>Canada Foundation for Innovation (CFI)</td><td>CFI</td><td>Infrastructure funding</td><td>$1M+</td><td>Varies</td><td>Annual reports: Jun 15</td><td>⚪ Not eligible directly</td><td>CFO</td><td>Partner with university for CFI-funded photonics lab access</td><td>30%</td><td>In-kind</td></tr>
  <tr><td>7</td><td>Ontario CTI</td><td>Ontario Government</td><td>Conditional grant</td><td>Up to $30M per applicant</td><td>Up to 50%</td><td>Program active Apr 2026–Mar 2029</td><td>🔴 Not eligible directly</td><td>CFO</td><td>Identify eligible delivery partner (university/not-for-profit)</td><td>25%</td><td>$250,000</td></tr>
  <tr><td>8</td><td>Canadian Semiconductor R&amp;D Delegation to Germany</td><td>Global Affairs Canada / NRC IRAP</td><td>Partnership development</td><td>Travel funding</td><td>Varies</td><td>EOI: Mar 29, 2026 (closed)</td><td>🔴 Closed</td><td>CEO</td><td>Monitor 2027 delegation</td><td>0% (this cycle)</td><td>—</td></tr>
  <tr><td>9</td><td>Canada-UK Semiconductors Competition</td><td>NRC IRAP / Innovate UK</td><td>Bilateral R&amp;D</td><td>Up to £500,000 (UK)</td><td>Varies</td><td>EOI: Jul 2025 (closed)</td><td>🔴 Closed</td><td>CTO</td><td>Monitor next bilateral call</td><td>0% (this cycle)</td><td>—</td></tr>
  <tr><td>10</td><td>Ontario Research Fund – Research Infrastructure (ORF-RI)</td><td>Ontario Government</td><td>Infrastructure funding</td><td>Varies</td><td>Varies</td><td>Annual intake</td><td>⚪ Evaluating</td><td>CFO</td><td>Assess eligibility with university partner</td><td>20%</td><td>$100,000</td></tr>
</table>

**Total Weighted Pipeline Value:** $1,160,000

**Status Legend:** 🟢 Active/Preparing | 🟡 In Discussion/Evaluating | 🔴 Closed/Missed | ⚪ Not Eligible/On Hold | ✅ Awarded

## Section 2: Active Grant Profiles

### 2.1 NRC IRAP

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Program</td><td>Industrial Research Assistance Program (IRAP)</td></tr>
  <tr><td>Agency</td><td>National Research Council Canada (NRC)</td></tr>
  <tr><td>Application Process</td><td>Advisor-led; no application form to download; continuous intake</td></tr>
  <tr><td>Key Contact</td><td>Industrial Technology Advisor (ITA) — Photonics specialist</td></tr>
  <tr><td>Eligibility</td><td>Incorporated, for-profit Canadian SME with ≤500 employees; developing innovative technology</td></tr>
  <tr><td>Funding Model</td><td>Non-repayable contribution; typically covers a portion of salary and contractor costs</td></tr>
  <tr><td>Project Fit</td><td>AI chip design (RISC-V64, GPU), photonics tensor accelerator (PTA)</td></tr>
  <tr><td>Critical Note</td><td>IRAP has a dedicated Photonics ITA and operates the Canadian Photonics Fabrication Centre (NRC-CPFC) in Ottawa</td></tr>
  <tr><td>Next Action</td><td>Schedule introductory meeting with ITA; prepare 2-page project summary</td></tr>
  <tr><td>Deadline</td><td>None (rolling intake)</td></tr>
</table>

**Application Checklist:**

- ☐ Identify and contact regional IRAP ITA
- ☐ Prepare company overview (incorporation, employees, revenue)
- ☐ Prepare technical project description (RISC-V64 SoC, GPU, PTA)
- ☐ Prepare budget and timeline
- ☐ Meet with ITA for initial screening
- ☐ Submit formal proposal (with ITA support)
- ☐ Await decision (average 3 months)

### 2.2 FABrIC – Fabrication Process Development Challenge (Round 3)

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Program</td><td>FABrIC Challenge Grants – Fabrication Process Development</td></tr>
  <tr><td>Agency</td><td>CMC Microsystems / ISED</td></tr>
  <tr><td>Total Program Funding</td><td>$217M over five years; up to $120M from ISED</td></tr>
  <tr><td>Max per Project</td><td>$1M (up to $1.5M in exceptional cases)</td></tr>
  <tr><td>Reimbursement Rate</td><td>40% of eligible project expenses</td></tr>
  <tr><td>Project Size</td><td>Min $675K / Max $4M</td></tr>
  <tr><td>Duration</td><td>Up to 24 months</td></tr>
  <tr><td>Management Fee</td><td>2.5% to CMC Microsystems</td></tr>
  <tr><td>Capital Equipment</td><td>Ineligible</td></tr>
  <tr><td>Exit TRL</td><td>TRL 7 or higher</td></tr>
  <tr><td>EOI Portal Opens</td><td>August 10, 2026</td></tr>
  <tr><td>EOI Due</td><td>September 8, 2026</td></tr>
  <tr><td>Full Proposal Invites</td><td>September 14, 2026</td></tr>
  <tr><td>Full Proposal Due</td><td>October 27, 2026</td></tr>
  <tr><td>Submission Portal</td><td>Blackbaud (account required)</td></tr>
  <tr><td>Project Fit</td><td>RISC-V64 SoC, GPU, PTA fabrication process development</td></tr>
</table>

**Application Checklist:**

- ☐ Create Blackbaud account
- ☐ Download EOI template and attestation/signature template
- ☐ Draft EOI (alignment with Fabrication Process Development themes)
- ☐ Identify Lead and Co-Lead structure (one Lead, one Co-Lead preferred)
- ☐ Prepare IP sharing agreement if multiple Co-Leads
- ☐ Submit EOI by September 8, 2026
- ☐ Await full proposal invitation (by September 14, 2026)
- ☐ Prepare full proposal (if invited)
- ☐ Submit full proposal by October 27, 2026

### 2.3 FABrIC – IoT Product Development Challenge (Round 3)

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Program</td><td>FABrIC Challenge Grants – IoT Product Development</td></tr>
  <tr><td>Agency</td><td>CMC Microsystems / ISED</td></tr>
  <tr><td>Max per Project</td><td>$1M</td></tr>
  <tr><td>Reimbursement Rate</td><td>37% of eligible project expenses</td></tr>
  <tr><td>Exit TRL</td><td>TRL 8 or higher</td></tr>
  <tr><td>EOI Due</td><td>September 8, 2026</td></tr>
  <tr><td>Full Proposal Due</td><td>October 27, 2026</td></tr>
  <tr><td>Project Fit</td><td>PDB development board for research organizations and academia</td></tr>
  <tr><td>Note</td><td>MNE (multinational enterprise) not eligible for funding; Collaborator only</td></tr>
</table>

**Application Checklist:**

- ☐ Confirm PDB project alignment with IoT application areas
- ☐ Create Blackbaud account (shared with Fabrication Process Development track)
- ☐ Draft EOI for IoT Product Development track
- ☐ Submit EOI by September 8, 2026
- ☐ Prepare full proposal (if invited)
- ☐ Submit full proposal by October 27, 2026

### 2.4 NSERC Alliance Advantage

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Program</td><td>Alliance Advantage (formerly Alliance cost-sharing option 1)</td></tr>
  <tr><td>Agency</td><td>NSERC</td></tr>
  <tr><td>Application Process</td><td>Continuous intake; no fixed deadline</td></tr>
  <tr><td>Eligibility</td><td>Requires academic partner (Canadian university)</td></tr>
  <tr><td>Funding Model</td><td>Cost-sharing between company and NSERC</td></tr>
  <tr><td>Project Fit</td><td>AI-driven chip design methodology; photonics tensor accelerator</td></tr>
  <tr><td>Next Action</td><td>Identify Canadian university with photonics/semiconductor research program</td></tr>
  <tr><td>Potential Partners</td><td>University of Waterloo, University of Toronto, McGill, UBC, INRS</td></tr>
</table>

**Application Checklist:**

- ☐ Identify academic collaborator and principal investigator
- ☐ Define research project scope and budget
- ☐ Prepare company contribution (cash and in-kind)
- ☐ Submit Alliance Advantage application via university research office
- ☐ Await peer review (typically 3–6 months)

### 2.5 Ontario CTI (via Delivery Partner)

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Program</td><td>Critical Technologies Initiative (CTI)</td></tr>
  <tr><td>Agency</td><td>Ontario Government</td></tr>
  <tr><td>Eligibility</td><td>Not-for-profit organizations only; for-profit companies must partner with eligible delivery organization</td></tr>
  <tr><td>Max per Applicant</td><td>Up to $30M (50% of eligible project costs)</td></tr>
  <tr><td>Program Period</td><td>April 1, 2026 – March 31, 2029</td></tr>
  <tr><td>Required Pillars</td><td>Must address 3+ of: Infrastructure, Commercialization, Adoption, Talent</td></tr>
  <tr><td>AI Requirement</td><td>Proposals must include AI initiatives</td></tr>
  <tr><td>Project Fit</td><td>PDB development board; AI chip design methodology</td></tr>
  <tr><td>Next Action</td><td>Identify eligible delivery partner (e.g., university, CMC Microsystems, not-for-profit research institute)</td></tr>
</table>

**Application Checklist:**

- ☐ Identify eligible delivery partner organization
- ☐ Define project scope addressing 3+ CTI pillars
- ☐ Confirm AI component is integrated
- ☐ Partner submits CTI application
- ☐ Your company is included as a project collaborator

## Section 3: Deadline Calendar

### 3.1 2026 Grant Deadlines

<table>
  <tr><th>Date</th><th>Grant Program</th><th>Milestone</th><th>Owner</th><th>Status</th></tr>
  <tr><td>Mar 25, 2026</td><td>NSERC-NSTC Semiconductor &amp; AI</td><td>LOI Deadline</td><td>Grant Admin</td><td>🔴 Missed</td></tr>
  <tr><td>Mar 29, 2026</td><td>Germany Semiconductor Delegation</td><td>EOI Deadline</td><td>CEO</td><td>🔴 Missed</td></tr>
  <tr><td>May 2026</td><td>FABrIC Round 2</td><td>Full Proposal (if invited)</td><td>CTO</td><td>✅ Submitted</td></tr>
  <tr><td>Jun 15, 2026</td><td>CFI</td><td>Annual Financial Report</td><td>CFO</td><td>⚪ Not applicable</td></tr>
  <tr><td>Jul 30, 2026</td><td>NSERC-NSTC Semiconductor &amp; AI</td><td>Full Proposal (by invite)</td><td>Grant Admin</td><td>🔴 Not invited</td></tr>
  <tr><td>Aug 10, 2026</td><td>FABrIC Round 3</td><td>EOI Portal Opens</td><td>CTO</td><td>🟢 Ready</td></tr>
  <tr><td>Sep 8, 2026</td><td>FABrIC Round 3</td><td>EOI Due</td><td>CTO</td><td>🟢 Preparing</td></tr>
  <tr><td>Sep 14, 2026</td><td>FABrIC Round 3</td><td>Full Proposal Invites</td><td>CTO</td><td>⏳ Awaiting</td></tr>
  <tr><td>Oct 27, 2026</td><td>FABrIC Round 3</td><td>Full Proposal Due</td><td>CTO</td><td>⏳ Pending</td></tr>
  <tr><td>Dec 1, 2026</td><td>FABrIC Round 4</td><td>EOI Due</td><td>CTO</td><td>🟡 Monitor</td></tr>
  <tr><td>Dec 11, 2026</td><td>FABrIC Round 4</td><td>Full Proposal Invites</td><td>CTO</td><td>⏳ Pending</td></tr>
  <tr><td>Feb 9, 2027</td><td>FABrIC Round 4</td><td>Full Proposal Due</td><td>CTO</td><td>⏳ Pending</td></tr>
</table>

### 3.2 Recurring Reporting Deadlines

<table>
  <tr><th>Frequency</th><th>Report</th><th>Agency</th><th>Deadline</th><th>Owner</th></tr>
  <tr><td>Quarterly</td><td>IRAP Progress Report</td><td>NRC IRAP</td><td>Per agreement</td><td>CFO</td></tr>
  <tr><td>Quarterly</td><td>FABrIC Reimbursement Claim</td><td>FABrIC</td><td>Per agreement</td><td>CFO</td></tr>
  <tr><td>Annual</td><td>CFI Financial Report</td><td>CFI</td><td>June 15</td><td>CFO</td></tr>
  <tr><td>Annual</td><td>CFI Progress Report</td><td>CFI</td><td>June 30</td><td>CTO</td></tr>
  <tr><td>Annual</td><td>NSERC Form 300</td><td>NSERC</td><td>September 30 (extended)</td><td>University partner</td></tr>
  <tr><td>Annual</td><td>Ontario CTI Report</td><td>Ontario</td><td>Per agreement</td><td>Delivery partner</td></tr>
</table>

## Section 4: Pipeline Management View

This view tracks each grant application through stages, from prospect to awarded.

<table>
  <tr><th>Stage</th><th>Definition</th><th>Grants Currently in Stage</th><th>Action Required</th></tr>
  <tr><td>Prospect</td><td>Identified as potential fit; not yet engaged</td><td>Ontario CTI (via partner), ORF-RI</td><td>Research eligibility; identify partners</td></tr>
  <tr><td>Qualifying</td><td>Initial contact made; eligibility confirmed</td><td>NRC IRAP, NSERC Alliance</td><td>Schedule meetings; prepare project briefs</td></tr>
  <tr><td>Preparing</td><td>Application in development</td><td>FABrIC Process Dev, FABrIC IoT</td><td>Draft EOI; prepare full proposal</td></tr>
  <tr><td>Submitted</td><td>Application submitted; awaiting decision</td><td>—</td><td>Monitor portal; respond to inquiries</td></tr>
  <tr><td>Awarded</td><td>Grant approved; funds committed</td><td>—</td><td>Set up compliance tracking</td></tr>
  <tr><td>Active</td><td>Grant funds being expended</td><td>—</td><td>Monthly grant accounting</td></tr>
  <tr><td>Closed</td><td>Grant completed; final report filed</td><td>—</td><td>Archive documentation</td></tr>
</table>

### 4.1 Pipeline Dashboard

<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>Total opportunities identified</td><td>10</td></tr>
  <tr><td>Active applications</td><td>4</td></tr>
  <tr><td>Total weighted pipeline</td><td>$1,160,000</td></tr>
  <tr><td>Total submitted (cumulative)</td><td>$400,000 (FABrIC Round 2)</td></tr>
  <tr><td>Total awarded (cumulative)</td><td>$0</td></tr>
  <tr><td>Success rate (trailing 12 months)</td><td>0% (first cycle)</td></tr>
  <tr><td>Target success rate</td><td>≥50%</td></tr>
  <tr><td>Proposals due in next 30 days</td><td>FABrIC Round 3 EOI (Sep 8, 2026)</td></tr>
</table>

## Section 5: Grant Compliance Tracking

Once a grant is awarded, compliance tracking becomes critical. This section tracks reporting obligations, expenditure milestones, and audit readiness.

### 5.1 Active Grant Compliance Matrix

<table>
  <tr><th>Grant</th><th>Award Amount</th><th>Reporting Frequency</th><th>Next Report Due</th><th>Expenditure to Date</th><th>Remaining Budget</th><th>Compliance Status</th></tr>
  <tr><td>[None awarded yet]</td><td>—</td><td>—</td><td>—</td><td>—</td><td>—</td><td>—</td></tr>
</table>

### 5.2 Grant Expenditure Tracking (Template)

<table>
  <tr><th>Cost Category</th><th>Budget</th><th>Expended</th><th>% Used</th><th>Remaining</th><th>Eligible?</th></tr>
  <tr><td>Personnel — Design Engineering</td><td>$600,000</td><td>$0</td><td>0%</td><td>$600,000</td><td>Yes</td></tr>
  <tr><td>Personnel — Contract Engineering</td><td>$176,000</td><td>$0</td><td>0%</td><td>$176,000</td><td>Yes</td></tr>
  <tr><td>Foundry — wafer.space</td><td>$24,000</td><td>$0</td><td>0%</td><td>$24,000</td><td>Yes</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$35,000</td><td>$0</td><td>0%</td><td>$35,000</td><td>Yes</td></tr>
  <tr><td>Assembly &amp; Test</td><td>$25,000</td><td>$0</td><td>0%</td><td>$25,000</td><td>Yes</td></tr>
  <tr><td>Board BOM</td><td>$35,000</td><td>$0</td><td>0%</td><td>$35,000</td><td>Yes</td></tr>
  <tr><td>EDA Software &amp; IP</td><td>$152,000</td><td>$0</td><td>0%</td><td>$152,000</td><td>Yes</td></tr>
  <tr><td>Mask &amp; Reticle</td><td>$22,500</td><td>$0</td><td>0%</td><td>$22,500</td><td>Yes</td></tr>
  <tr><td>Prototype &amp; Test</td><td>$100,000</td><td>$0</td><td>0%</td><td>$100,000</td><td>Yes</td></tr>
  <tr><td>PCB Development</td><td>$15,000</td><td>$0</td><td>0%</td><td>$15,000</td><td>Yes</td></tr>
  <tr><td>Total</td><td>$1,184,500</td><td>$0</td><td>0%</td><td>$1,184,500</td><td></td></tr>
</table>

### 5.3 Audit Readiness Checklist

<table>
  <tr><th>#</th><th>Item</th><th>Status</th><th>Location</th></tr>
  <tr><td>1</td><td>Grant agreement signed and filed</td><td>☐</td><td>Compliance folder</td></tr>
  <tr><td>2</td><td>Timesheets for all grant-funded personnel</td><td>☐</td><td>HR / Grant Admin</td></tr>
  <tr><td>3</td><td>Supplier invoices (wafer.space, GF/AMF, PCB vendors)</td><td>☐</td><td>AP system</td></tr>
  <tr><td>4</td><td>Payroll registers with grant allocation</td><td>☐</td><td>Payroll system</td></tr>
  <tr><td>5</td><td>Bank statements showing grant expenditures</td><td>☐</td><td>Treasury</td></tr>
  <tr><td>6</td><td>Grant claim calculations and supporting documents</td><td>☐</td><td>Finance</td></tr>
  <tr><td>7</td><td>IP disclosure forms</td><td>☐</td><td>Legal</td></tr>
  <tr><td>8</td><td>Publication acknowledgements</td><td>☐</td><td>Communications</td></tr>
  <tr><td>9</td><td>Certificate of compliance (signed)</td><td>☐</td><td>Compliance folder</td></tr>
</table>

## Section 6: Grant Application Workflow Checklist

### 6.1 Phase 1: Opportunity Identification & Qualification

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deadline</th><th>Done</th></tr>
  <tr><td>1.1</td><td>Monitor grant agency websites for new calls</td><td>Grant Admin</td><td>Weekly</td><td>☐</td></tr>
  <tr><td>1.2</td><td>Assess eligibility against company profile</td><td>CFO</td><td>Within 3 days</td><td>☐</td></tr>
  <tr><td>1.3</td><td>Assess project fit against grant objectives</td><td>CTO</td><td>Within 5 days</td><td>☐</td></tr>
  <tr><td>1.4</td><td>Add opportunity to master tracker</td><td>Grant Admin</td><td>Same day</td><td>☐</td></tr>
  <tr><td>1.5</td><td>Schedule initial call with program advisor (if applicable)</td><td>CFO</td><td>Within 2 weeks</td><td>☐</td></tr>
  <tr><td>1.6</td><td>Decision: proceed to preparation or defer</td><td>CFO / CTO</td><td>Within 2 weeks</td><td>☐</td></tr>
</table>

### 6.2 Phase 2: Application Preparation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deadline</th><th>Done</th></tr>
  <tr><td>2.1</td><td>Download application templates and guidelines</td><td>Grant Admin</td><td>Immediately</td><td>☐</td></tr>
  <tr><td>2.2</td><td>Create application account (e.g., Blackbaud for FABrIC)</td><td>Grant Admin</td><td>Immediately</td><td>☐</td></tr>
  <tr><td>2.3</td><td>Prepare technical project description</td><td>CTO</td><td>4 weeks before deadline</td><td>☐</td></tr>
  <tr><td>2.4</td><td>Prepare budget and financial projections</td><td>CFO</td><td>4 weeks before deadline</td><td>☐</td></tr>
  <tr><td>2.5</td><td>Secure partner letters of support (academic, industry)</td><td>Grant Admin</td><td>3 weeks before deadline</td><td>☐</td></tr>
  <tr><td>2.6</td><td>Prepare IP disclosure and sharing agreements</td><td>Legal</td><td>3 weeks before deadline</td><td>☐</td></tr>
  <tr><td>2.7</td><td>Internal review of draft application</td><td>CFO / CTO</td><td>2 weeks before deadline</td><td>☐</td></tr>
  <tr><td>2.8</td><td>Incorporate feedback and finalize</td><td>Grant Admin</td><td>1 week before deadline</td><td>☐</td></tr>
  <tr><td>2.9</td><td>Submit application</td><td>Grant Admin</td><td>Before deadline</td><td>☐</td></tr>
</table>

### 6.3 Phase 3: Post-Submission

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deadline</th><th>Done</th></tr>
  <tr><td>3.1</td><td>Confirm submission receipt</td><td>Grant Admin</td><td>Same day</td><td>☐</td></tr>
  <tr><td>3.2</td><td>Update tracker with submission date and status</td><td>Grant Admin</td><td>Same day</td><td>☐</td></tr>
  <tr><td>3.3</td><td>Respond to agency inquiries within 48 hours</td><td>Grant Admin</td><td>As needed</td><td>☐</td></tr>
  <tr><td>3.4</td><td>Prepare for potential site visit or interview</td><td>CTO / CFO</td><td>As scheduled</td><td>☐</td></tr>
  <tr><td>3.5</td><td>Await decision</td><td>—</td><td>—</td><td>☐</td></tr>
</table>

### 6.4 Phase 4: Award Management (Post-Award)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deadline</th><th>Done</th></tr>
  <tr><td>4.1</td><td>Review and sign grant agreement</td><td>CFO</td><td>Upon receipt</td><td>☐</td></tr>
  <tr><td>4.2</td><td>Set up grant-specific accounting codes</td><td>Controller</td><td>Within 1 week</td><td>☐</td></tr>
  <tr><td>4.3</td><td>Set up grant compliance calendar</td><td>Grant Admin</td><td>Within 1 week</td><td>☐</td></tr>
  <tr><td>4.4</td><td>Brief project team on reporting requirements</td><td>Grant Admin</td><td>Within 2 weeks</td><td>☐</td></tr>
  <tr><td>4.5</td><td>Begin monthly grant expenditure tracking</td><td>Controller</td><td>Month-end</td><td>☐</td></tr>
  <tr><td>4.6</td><td>Prepare and submit first progress report</td><td>Grant Admin</td><td>Per agreement</td><td>☐</td></tr>
</table>

## Section 7: Grant Application Tracker Dashboard

<table>
  <tr><th>KPI</th><th>Target</th><th>Current</th><th>Status</th></tr>
  <tr><td>Total weighted pipeline</td><td>≥$1,000,000</td><td>$1,160,000</td><td>🟢</td></tr>
  <tr><td>Active applications</td><td>≥4</td><td>4</td><td>🟢</td></tr>
  <tr><td>Applications submitted (YTD)</td><td>≥2</td><td>1</td><td>🟡</td></tr>
  <tr><td>Awards (YTD)</td><td>≥1</td><td>0</td><td>🔴</td></tr>
  <tr><td>Success rate (trailing 12 months)</td><td>≥50%</td><td>0%</td><td>🔴</td></tr>
  <tr><td>Proposals due within 30 days</td><td>—</td><td>1 (FABrIC EOI)</td><td>🟡</td></tr>
  <tr><td>Compliance reports overdue</td><td>0</td><td>0</td><td>🟢</td></tr>
  <tr><td>Audit readiness score</td><td>≥90%</td><td>N/A (no active grants)</td><td>⚪</td></tr>
</table>

**Overall Grant Program Health:** 🟡 — Strong pipeline, but no awards yet. Focus on FABrIC Round 3 EOI (Sep 8) and NRC IRAP engagement.

## Section 8: Key Contacts

<table>
  <tr><th>Organization</th><th>Contact Type</th><th>Name</th><th>Email</th><th>Phone</th></tr>
  <tr><td>NRC IRAP</td><td>Photonics ITA</td><td>[TBD]</td><td>[TBD]</td><td>[TBD]</td></tr>
  <tr><td>FABrIC / CMC Microsystems</td><td>Program Advisor</td><td>[TBD]</td><td>challenges@fabricinnovation.ca</td><td>—</td></tr>
  <tr><td>NSERC</td><td>Program Officer</td><td>[TBD]</td><td>[TBD]</td><td>[TBD]</td></tr>
  <tr><td>Ontario CTI</td><td>Program Officer</td><td>[TBD]</td><td>[TBD]</td><td>[TBD]</td></tr>
  <tr><td>University Partner (NSERC)</td><td>Principal Investigator</td><td>[TBD]</td><td>[TBD]</td><td>—</td></tr>
</table>

## Section 9: Grant Policy Notes

<table>
  <tr><th>Policy</th><th>Detail</th></tr>
  <tr><td>Eligible cost documentation</td><td>Every grant-funded expenditure must be supported by invoice, timesheet, or payroll record</td></tr>
  <tr><td>Segregation of duties</td><td>Grant expenditures approved by CFO; reviewed by CTO</td></tr>
  <tr><td>Timesheet policy</td><td>Contemporaneous timesheets required for all personnel charging to grants</td></tr>
  <tr><td>Procurement policy</td><td>Competitive bidding required for purchases &gt; $10,000</td></tr>
  <tr><td>Related-party disclosure</td><td>All related-party transactions must be disclosed to granting agency</td></tr>
  <tr><td>IP disclosure</td><td>New IP must be disclosed within 30 days of creation</td></tr>
  <tr><td>Publication acknowledgement</td><td>All publications must acknowledge grant support</td></tr>
  <tr><td>Record retention</td><td>Grant records retained for 7 years after grant completion</td></tr>
  <tr><td>Audit cooperation</td><td>Company will cooperate fully with agency audits</td></tr>
</table>

## Section 10: Tracker Maintenance & Governance

<table>
  <tr><th>Activity</th><th>Frequency</th><th>Owner</th><th>Output</th></tr>
  <tr><td>Update opportunity tracker</td><td>Weekly</td><td>Grant Admin</td><td>Updated status column</td></tr>
  <tr><td>Review pipeline with CFO</td><td>Bi-weekly</td><td>Grant Admin / CFO</td><td>Pipeline health assessment</td></tr>
  <tr><td>Update weighted values</td><td>Monthly</td><td>CFO</td><td>Revised pipeline value</td></tr>
  <tr><td>Reconcile grant expenditures</td><td>Monthly (at close)</td><td>Controller</td><td>Grant expenditure report</td></tr>
  <tr><td>Review compliance calendar</td><td>Monthly</td><td>Grant Admin</td><td>Updated deadlines</td></tr>
  <tr><td>Prepare board grant summary</td><td>Quarterly</td><td>CFO</td><td>Board reporting package</td></tr>
  <tr><td>Audit readiness review</td><td>Semi-annual</td><td>CFO</td><td>Audit readiness score</td></tr>
  <tr><td>Grant policy review</td><td>Annual</td><td>CFO</td><td>Updated policies</td></tr>
</table>

---

This grant application tracker gives you a complete operational framework for identifying, pursuing, and managing Canadian grant opportunities for your RISC-V64 SoC, GPU, PTA, and PDB development board projects. The key insight is that **FABrIC Round 3** is your most immediate and highest-value opportunity — the EOI is due **September 8, 2026**, and your projects align directly with both the Fabrication Process Development and IoT Product Development tracks. I recommend prioritizing the Blackbaud account setup and EOI drafting this week.

---

# Foundry Partner Scorecard: [wafer.space](https://wafer.space/) & GlobalFoundries / AMF

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Scorecard Owner:** Foundry Operations / CFO  
**Review Cadence:** Quarterly (with monthly data collection)  
**Reporting Period:** [Quarter] [Year]

## Section 1: Scorecard Design Principles

This scorecard is built on the weighted-scoring model used across semiconductor supplier management. A supplier scorecard converts quality, delivery, cost, and compliance data into one weighted score for objective vendor comparison. Rather than evaluating each dimension in isolation, the scorecard produces a single, comparable rating that supports sourcing decisions and renewal negotiations.

The design follows the five-dimension evaluation framework used by leading foundries: **quality, cost, delivery, service, and sustainability**. For a fabless company working with MPW shuttle partners, these dimensions are adapted to reflect the unique economics of multi-project wafer fabrication, where yield, DRC adherence, and schedule reliability are the primary value drivers.

**Key design principles:**

- **Driver-based scoring:** Each KPI traces to a measurable data source ([wafer.space](https://wafer.space/) portal, GF Connect, yield reports)
- **Weighted composite:** Each dimension carries a weight reflecting its strategic importance to your business
- **Actionable thresholds:** Every score maps to a specific escalation or corrective action
- **Comparative baseline:** Scores are tracked quarter-over-quarter to identify trends before they become crises
- **Two-tier structure:** A universal scorecard applies to both partners, with partner-specific KPI customization

## Section 2: Weighted Scoring Dimensions

### 2.1 Dimension Weights

<table>
  <tr><th>Dimension</th><th>Weight</th><th>Rationale</th></tr>
  <tr><td>Quality &amp; Yield</td><td>35%</td><td>The single largest driver of unit economics; a 5% yield drop can destroy 20–40% of EBITDA</td></tr>
  <tr><td>Delivery &amp; Schedule</td><td>25%</td><td>MPW shuttle deadlines are fixed and non-negotiable; missing one defers fabrication by a full quarter</td></tr>
  <tr><td>Cost &amp; Commercial Terms</td><td>20%</td><td>Foundry costs represent the largest COGS component; PPV directly impacts gross margin</td></tr>
  <tr><td>Technical Support &amp; Responsiveness</td><td>12%</td><td>DRC iterations, PDK support, and design-for-manufacturing guidance reduce rework</td></tr>
  <tr><td>Compliance &amp; Sustainability</td><td>8%</td><td>Required for grant eligibility (FABrIC, NRC IRAP) and ESG reporting</td></tr>
</table>

**Weighting note:** The 35% quality weight aligns with semiconductor industry benchmarks where supplier quality accounts for 35% of the total scorecard score, and delivery accounts for 30%. Cost is weighted lower than in general manufacturing because yield and schedule reliability have a greater impact on total cost of ownership than unit price alone.

## Section 3: KPI Definitions & Scoring Targets

### 3.1 Quality & Yield (35%)

<table>
  <tr><th>KPI</th><th>Definition</th><th>Data Source</th><th>Target</th><th>Weight</th></tr>
  <tr><td>Wafer/die yield</td><td>Actual yield vs. standard yield for the specific design and process</td><td>Foundry yield report</td><td>≥ Standard yield</td><td>15%</td></tr>
  <tr><td>Yield consistency</td><td>Standard deviation of yield across lots in the review period</td><td>Foundry yield report</td><td>≤ 2 pp</td><td>8%</td></tr>
  <tr><td>DRC iteration count</td><td>Number of DRC iterations required to achieve clean DRC</td><td>Submission platform</td><td>≤ 3 iterations</td><td>5%</td></tr>
  <tr><td>Defect density</td><td>Defects per cm² (moving average)</td><td>Foundry quality report</td><td>&lt; 0.08 defects/cm²</td><td>4%</td></tr>
  <tr><td>Lot reject rate</td><td>% of lots rejected due to material or process issues</td><td>Foundry quality report</td><td>&lt; 0.5%</td><td>3%</td></tr>
</table>

**Industry benchmarks:** Defect density target of < 0.08 defects/cm² (moving average) and lot reject rate < 0.5% are drawn from semiconductor material standards. DRC iteration limit of 3 is a GlobalFoundries/AMF contractual requirement: "Max 3 DRC iterations by AMF. Any DRC violation must be waived by this date".

### 3.2 Delivery & Schedule (25%)

<table>
  <tr><th>KPI</th><th>Definition</th><th>Data Source</th><th>Target</th><th>Weight</th></tr>
  <tr><td>On-time delivery (OTD)</td><td>% of lots delivered on or before the committed date</td><td>Foundry portal / shipping notices</td><td>&gt; 98%</td><td>10%</td></tr>
  <tr><td>Schedule adherence</td><td>% of milestone dates met (GDS submission, DRC clean, tape-out, delivery)</td><td>Foundry portal</td><td>100%</td><td>8%</td></tr>
  <tr><td>Lead time adherence</td><td>Actual cycle time vs. committed cycle time</td><td>Foundry portal</td><td>≤ Committed</td><td>4%</td></tr>
  <tr><td>Sample quantity</td><td>Die/chip count delivered vs. committed</td><td>Receiving report</td><td>≥ 100%</td><td>3%</td></tr>
</table>

**Industry benchmarks:** On-time delivery target of > 98% and order fill rate > 99.5% are standard semiconductor supply chain metrics. GlobalFoundries GlobalShuttle commits to delivering up to 100 die samples as part of the base MPW fee for qualifying runs.

### 3.3 Cost & Commercial Terms (20%)

<table>
  <tr><th>KPI</th><th>Definition</th><th>Data Source</th><th>Target</th><th>Weight</th></tr>
  <tr><td>Purchase price variance (PPV)</td><td>Actual slot price vs. budgeted/standard price</td><td>AP sub-ledger</td><td>≤ 5% variance</td><td>8%</td></tr>
  <tr><td>Cost per good die</td><td>Total foundry cost ÷ good die count</td><td>Yield report + AP</td><td>≤ Standard cost</td><td>6%</td></tr>
  <tr><td>Payment terms adherence</td><td>Invoicing accuracy and adherence to agreed payment schedule</td><td>AP aging</td><td>100% accuracy</td><td>3%</td></tr>
  <tr><td>Price stability</td><td>Slot price consistency across runs</td><td>Purchase history</td><td>No unplanned increases</td><td>3%</td></tr>
</table>

**Industry benchmarks:** PPV target of ≤ 5% variance is derived from semiconductor cost metrics where "Total cost of ownership (TCO) trending down 2-5% annually" is the standard. The cost per good die metric captures the compounding effect of yield on unit economics.

### 3.4 Technical Support & Responsiveness (12%)

<table>
  <tr><th>KPI</th><th>Definition</th><th>Data Source</th><th>Target</th><th>Weight</th></tr>
  <tr><td>DRC support responsiveness</td><td>Time to resolve DRC queries and provide rule deck clarifications</td><td>Email/portal logs</td><td>&lt; 24 hours</td><td>4%</td></tr>
  <tr><td>PDK quality</td><td>Completeness and accuracy of process design kit</td><td>Design team feedback</td><td>No blocking issues</td><td>3%</td></tr>
  <tr><td>Design-for-manufacturing (DFM) guidance</td><td>Proactive DFM feedback beyond DRC</td><td>Design team feedback</td><td>Provided when requested</td><td>3%</td></tr>
  <tr><td>Issue escalation path</td><td>Clarity and effectiveness of escalation process</td><td>Escalation log</td><td>Resolved within 5 business days</td><td>2%</td></tr>
</table>

**Industry benchmark:** Technical support responsiveness target of < 24 hours average is a standard semiconductor supplier performance metric.

### 3.5 Compliance & Sustainability (8%)

<table>
  <tr><th>KPI</th><th>Definition</th><th>Data Source</th><th>Target</th><th>Weight</th></tr>
  <tr><td>Grant compliance support</td><td>Provision of documentation required for FABrIC/NRC IRAP claims</td><td>Grant Admin</td><td>Complete within 5 business days</td><td>3%</td></tr>
  <tr><td>Conflict minerals compliance</td><td>RMAP conformance of smelters in supply chain</td><td>Supplier disclosure</td><td>≥ 99% conformant</td><td>2%</td></tr>
  <tr><td>Environmental compliance</td><td>Compliance with applicable environmental regulations</td><td>Supplier disclosure</td><td>No findings</td><td>2%</td></tr>
  <tr><td>Business continuity</td><td>Existence and adequacy of business continuity plan</td><td>Supplier documentation</td><td>Plan on file</td><td>1%</td></tr>
</table>

**Industry benchmark:** GlobalFoundries reports that 99.5% of its identified smelters were RMAP conformant as of December 31, 2025. GF considers VAP audits with scores below 180 points (below RBA "Gold" Level) as needing corrective actions.

## Section 4: Scoring Guide (1–5 Scale)

Each KPI is scored on a 1–5 scale. The weighted score is calculated as: **KPI Score × KPI Weight × Dimension Weight**.

<table>
  <tr><th>Score</th><th>Rating</th><th>Definition</th><th>Action Required</th></tr>
  <tr><td>5</td><td>Excellent</td><td>Exceeds target; best-in-class performance</td><td>Recognize; consider expanded partnership</td></tr>
  <tr><td>4</td><td>Good</td><td>Meets target consistently</td><td>Monitor; no action required</td></tr>
  <tr><td>3</td><td>Satisfactory</td><td>Meets target with occasional misses</td><td>Review with partner; identify improvement</td></tr>
  <tr><td>2</td><td>Needs Improvement</td><td>Below target in one or more areas</td><td>Formal corrective action plan required</td></tr>
  <tr><td>1</td><td>Unacceptable</td><td>Significantly below target; material impact</td><td>Escalate to executive level; consider alternative partner</td></tr>
</table>

**Composite Score Interpretation:**

<table>
  <tr><th>Composite Score</th><th>Grade</th><th>Action</th></tr>
  <tr><td>4.5–5.0</td><td>A</td><td>Strategic partner; expand engagement</td></tr>
  <tr><td>3.5–4.4</td><td>B</td><td>Preferred partner; maintain relationship</td></tr>
  <tr><td>2.5–3.4</td><td>C</td><td>Conditional partner; corrective action plan required</td></tr>
  <tr><td>1.5–2.4</td><td>D</td><td>Probationary; qualify alternative partner</td></tr>
  <tr><td>1.0–1.4</td><td>F</td><td>Terminate; transition to alternative</td></tr>
</table>

## Section 5: [Wafer.space](https://wafer.space/) Scorecard — GF180MCU MPW

### 5.1 Partner Profile

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Partner</td><td>wafer.space</td></tr>
  <tr><td>Services</td><td>GF180MCU MPW shuttle aggregation, dicing, packaging, logistics</td></tr>
  <tr><td>Process</td><td>GF180MCU (180nm mixed-signal)</td></tr>
  <tr><td>Chips</td><td>RISC-V64 SoC, GPU</td></tr>
  <tr><td>Run Reference</td><td>GF180MCU Run 3</td></tr>
  <tr><td>Slot Size</td><td>Up to 3.88mm × 5.07mm (~20mm²)</td></tr>
  <tr><td>Price</td><td>Starting from $2,000/slot (early bird); standard $8,000</td></tr>
  <tr><td>Quantity</td><td>1,000 chips per slot</td></tr>
</table>

### 5.2 Quarterly Scorecard

<table>
  <tr><th>Dimension</th><th>KPI</th><th>Weight</th><th>Score (1–5)</th><th>Weighted Score</th><th>Notes</th></tr>
  <tr><td>Quality &amp; Yield (35%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Wafer/die yield</td><td>15%</td><td>2</td><td>0.105</td><td>RISC-V64: 88% vs. 95% std; GPU: 78% vs. 90% std</td></tr>
  <tr><td></td><td>Yield consistency</td><td>8%</td><td>3</td><td>0.084</td><td>One lot with outlier yield</td></tr>
  <tr><td></td><td>DRC iteration count</td><td>5%</td><td>4</td><td>0.070</td><td>2 iterations (within limit)</td></tr>
  <tr><td></td><td>Defect density</td><td>4%</td><td>4</td><td>0.056</td><td>&lt; 0.08 defects/cm²</td></tr>
  <tr><td></td><td>Lot reject rate</td><td>3%</td><td>5</td><td>0.050</td><td>&lt; 0.5%</td></tr>
  <tr><td>Delivery &amp; Schedule (25%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>On-time delivery</td><td>10%</td><td>5</td><td>0.125</td><td>Delivered on schedule</td></tr>
  <tr><td></td><td>Schedule adherence</td><td>8%</td><td>5</td><td>0.100</td><td>All milestones met</td></tr>
  <tr><td></td><td>Lead time adherence</td><td>4%</td><td>4</td><td>0.040</td><td>On target</td></tr>
  <tr><td></td><td>Sample quantity</td><td>3%</td><td>5</td><td>0.038</td><td>1,000 die delivered</td></tr>
  <tr><td>Cost &amp; Commercial Terms (20%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Purchase price variance</td><td>8%</td><td>1</td><td>0.016</td><td>$8,000 vs. $2,000 (300% PPV)</td></tr>
  <tr><td></td><td>Cost per good die</td><td>6%</td><td>2</td><td>0.024</td><td>$2.27 vs. $2.11 standard</td></tr>
  <tr><td></td><td>Payment terms adherence</td><td>3%</td><td>5</td><td>0.030</td><td>Invoicing accurate</td></tr>
  <tr><td></td><td>Price stability</td><td>3%</td><td>3</td><td>0.018</td><td>Run 3 pricing above Run 2</td></tr>
  <tr><td>Technical Support (12%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>DRC support responsiveness</td><td>4%</td><td>4</td><td>0.019</td><td>&lt; 24 hours</td></tr>
  <tr><td></td><td>PDK quality</td><td>3%</td><td>4</td><td>0.014</td><td>Minor documentation gaps</td></tr>
  <tr><td></td><td>DFM guidance</td><td>3%</td><td>3</td><td>0.011</td><td>Provided on request</td></tr>
  <tr><td></td><td>Issue escalation</td><td>2%</td><td>4</td><td>0.010</td><td>Resolved in 3 days</td></tr>
  <tr><td>Compliance (8%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Grant compliance support</td><td>3%</td><td>5</td><td>0.038</td><td>Documentation provided promptly</td></tr>
  <tr><td></td><td>Conflict minerals</td><td>2%</td><td>5</td><td>0.025</td><td>Compliant</td></tr>
  <tr><td></td><td>Environmental</td><td>2%</td><td>5</td><td>0.025</td><td>Compliant</td></tr>
  <tr><td></td><td>Business continuity</td><td>1%</td><td>3</td><td>0.008</td><td>Plan not formally documented</td></tr>
  <tr><td>Total</td><td></td><td>100%</td><td></td><td>0.906</td><td></td></tr>
</table>

### 5.3 Composite Score: **0.91 / 5.0 — Grade: F**

**Critical Issue:** The [wafer.space](https://wafer.space/) score is dominated by the catastrophic PPV (Purchase Price Variance) on the GF180MCU Run 3 slots. The $8,000/slot price versus the $2,000 early-bird target represents a **300% variance**, which alone accounts for **$18,000 in unfavorable PPV** and reduces the weighted score by nearly 0.4 points. The yield misses on both the RISC-V64 SoC (88% vs. 95%) and GPU (78% vs. 90%) compound the problem.

**Note:** The low composite score reflects **your company's failure to meet the early-bird deadline** as much as [wafer.space](https://wafer.space/)'s performance. The scorecard should distinguish between partner-controlled factors and customer-controlled factors.

### 5.4 Corrective Action Plan

<table>
  <tr><th>#</th><th>Issue</th><th>Root Cause</th><th>Partner-Controlled?</th><th>Corrective Action</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td>Slot PPV of $18,000</td><td>Missed early-bird deadline of 09 Dec 2026</td><td>No (customer)</td><td>Implement design freeze 4 weeks before slot deadline</td><td>Program Mgmt</td><td>Immediate</td></tr>
  <tr><td>2</td><td>RISC-V64 yield at 88%</td><td>NPU clock domain crossing metastability</td><td>No (design)</td><td>Enhance AI verification with formal CDC checks</td><td>Design Eng</td><td>Run 4</td></tr>
  <tr><td>3</td><td>GPU yield at 78%</td><td>Stitch boundary overlay error &gt; 50nm</td><td>Partially</td><td>Collaborate with wafer.space on stitch optimization</td><td>Foundry Ops</td><td>Run 4</td></tr>
  <tr><td>4</td><td>Price stability concern</td><td>Run 3 pricing above Run 2</td><td>Partially</td><td>Negotiate multi-run pricing agreement</td><td>CFO</td><td>Q1 2028</td></tr>
</table>

**[wafer.space](https://wafer.space/)-Specific Notes:** [wafer.space](https://wafer.space/) has demonstrated strong operational execution — on-time delivery, sample quantity, and payment terms all scored 5/5. The platform improvements in Run 2 (multiple slot sizes, improved DRC tooling, streamlined submission platform) show responsiveness to customer feedback. The launch of half-slot and full-slot options for Run 2 directly addressed the cost-of-entry concern that affected Run 1 participants. The partnership is operationally sound; the issues are primarily on the demand-side (customer readiness) and design-side (yield optimization).

## Section 6: GlobalFoundries / AMF Scorecard — Photonics MPW

### 6.1 Partner Profile

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Partner</td><td>GlobalFoundries / Advanced Micro Foundry (AMF)</td></tr>
  <tr><td>Services</td><td>Silicon photonics MPW shuttle, DRC support, PDK access</td></tr>
  <tr><td>Process</td><td>AMF silicon photonics platform (acquired by GF)</td></tr>
  <tr><td>Chip</td><td>PTA (Photonics Tensor Accelerator)</td></tr>
  <tr><td>Access</td><td>Commercial; quote required</td></tr>
  <tr><td>Submission Deadline</td><td>GDS by 15th of the previous month</td></tr>
  <tr><td>DRC Limit</td><td>Max 3 DRC iterations by AMF</td></tr>
</table>

### 6.2 Quarterly Scorecard

<table>
  <tr><th>Dimension</th><th>KPI</th><th>Weight</th><th>Score (1–5)</th><th>Weighted Score</th><th>Notes</th></tr>
  <tr><td>Quality &amp; Yield (35%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Wafer/die yield</td><td>15%</td><td>2</td><td>0.105</td><td>PTA: 72% vs. 85% std</td></tr>
  <tr><td></td><td>Yield consistency</td><td>8%</td><td>3</td><td>0.084</td><td>One lot</td></tr>
  <tr><td></td><td>DRC iteration count</td><td>5%</td><td>2</td><td>0.035</td><td>5 iterations (exceeds limit of 3)</td></tr>
  <tr><td></td><td>Defect density</td><td>4%</td><td>3</td><td>0.042</td><td>Within acceptable range</td></tr>
  <tr><td></td><td>Lot reject rate</td><td>3%</td><td>4</td><td>0.040</td><td>Low reject rate</td></tr>
  <tr><td>Delivery &amp; Schedule (25%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>On-time delivery</td><td>10%</td><td>5</td><td>0.125</td><td>Delivered per schedule</td></tr>
  <tr><td></td><td>Schedule adherence</td><td>8%</td><td>4</td><td>0.100</td><td>Minor DRC delay</td></tr>
  <tr><td></td><td>Lead time adherence</td><td>4%</td><td>4</td><td>0.040</td><td>On target</td></tr>
  <tr><td></td><td>Sample quantity</td><td>3%</td><td>4</td><td>0.030</td><td>Meeting committed quantity</td></tr>
  <tr><td>Cost &amp; Commercial Terms (20%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Purchase price variance</td><td>8%</td><td>3</td><td>0.048</td><td>$42,000 vs. $35,000 quote (20% PPV)</td></tr>
  <tr><td></td><td>Cost per good die</td><td>6%</td><td>2</td><td>0.024</td><td>$97.22 vs. $82.35 standard</td></tr>
  <tr><td></td><td>Payment terms adherence</td><td>3%</td><td>4</td><td>0.024</td><td>Minor invoicing questions</td></tr>
  <tr><td></td><td>Price stability</td><td>3%</td><td>4</td><td>0.024</td><td>Quote-based; reasonable</td></tr>
  <tr><td>Technical Support (12%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>DRC support responsiveness</td><td>4%</td><td>3</td><td>0.014</td><td>48–72 hour response</td></tr>
  <tr><td></td><td>PDK quality</td><td>3%</td><td>3</td><td>0.011</td><td>Adequate but room for improvement</td></tr>
  <tr><td></td><td>DFM guidance</td><td>3%</td><td>3</td><td>0.011</td><td>Available on request</td></tr>
  <tr><td></td><td>Issue escalation</td><td>2%</td><td>3</td><td>0.008</td><td>Escalation path unclear</td></tr>
  <tr><td>Compliance (8%)</td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td></td><td>Grant compliance support</td><td>3%</td><td>4</td><td>0.030</td><td>Documentation available</td></tr>
  <tr><td></td><td>Conflict minerals</td><td>2%</td><td>5</td><td>0.025</td><td>99.5% RMAP conformant</td></tr>
  <tr><td></td><td>Environmental</td><td>2%</td><td>5</td><td>0.025</td><td>Compliant</td></tr>
  <tr><td></td><td>Business continuity</td><td>1%</td><td>5</td><td>0.013</td><td>Strong corporate parent</td></tr>
  <tr><td>Total</td><td></td><td>100%</td><td></td><td>0.904</td><td></td></tr>
</table>

### 6.3 Composite Score: **0.90 / 5.0 — Grade: F**

**Critical Issue:** The GF/AMF score is driven by the PTA photonics yield miss (72% vs. 85% standard) and the DRC iteration overrun (5 vs. 3 limit). The yield gap accounts for **$5,353 in unfavorable yield variance**, and the additional DRC iterations add approximately **$7,000 in PPV**. The cost per good chip of $97.22 versus the standard $82.35 represents an **18% cost overrun** per unit.

**GF/AMF-Specific Notes:** GlobalFoundries acquired AMF in November 2025, making GF the largest pure-play silicon photonics foundry by revenue. The acquisition is still being integrated, which may explain some of the DRC support responsiveness issues. GF's GlobalShuttle program offers "increased shuttle frequency, reduced minimum area requirements, and option to increase samples provided" — features that should benefit your future photonics runs once the integration is complete. GF's supplier management program includes a Global Supplier Rating (GSR) system and segmented supplier performance management, indicating a mature approach to supplier quality.

### 6.4 Corrective Action Plan

<table>
  <tr><th>#</th><th>Issue</th><th>Root Cause</th><th>Partner-Controlled?</th><th>Corrective Action</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td>PTA yield at 72%</td><td>Grating coupler insertion loss &gt; 3dB</td><td>Partially</td><td>AMF DOE run to characterize waveguide loss ($45,000)</td><td>Photonics Eng</td><td>Q1 2028</td></tr>
  <tr><td>2</td><td>DRC overrun (5 vs. 3)</td><td>AMF-specific DRC rules not integrated into AI design tool</td><td>No (design)</td><td>Integrate AMF DRC rule deck into AI photonic design tool</td><td>Design Automation</td><td>Q1 2028</td></tr>
  <tr><td>3</td><td>PPV of $7,000</td><td>Additional DRC iterations at $3,500 each</td><td>Partially</td><td>Pre-validate photonic layouts against AMF rules before submission</td><td>Photonics Eng</td><td>Immediate</td></tr>
  <tr><td>4</td><td>Cost per good chip</td><td>Yield gap compounds unit cost</td><td>Yes</td><td>Negotiate yield improvement commitment in next MPW agreement</td><td>CFO</td><td>Q2 2028</td></tr>
</table>

**GF/AMF Strategic Recommendation:** Given GF's acquisition of AMF and the partnership with SMART Photonics for open-access photonics services, your company should prioritize securing a multi-run pricing agreement that includes yield improvement targets. The open access service combining GF's silicon platform with SMART Photonics' indium phosphide (InP) PICs is targeted for general availability in the second half of 2027 — this could be a future opportunity to improve PTA performance.

## Section 7: Comparative Dashboard

### 7.1 Side-by-Side Scorecard Summary

<table>
  <tr><th>Dimension</th><th>wafer.space</th><th>GF/AMF</th><th>Delta</th></tr>
  <tr><td>Quality &amp; Yield</td><td>0.365</td><td>0.306</td><td>+0.059</td></tr>
  <tr><td>Delivery &amp; Schedule</td><td>0.303</td><td>0.295</td><td>+0.008</td></tr>
  <tr><td>Cost &amp; Commercial Terms</td><td>0.088</td><td>0.120</td><td>−0.032</td></tr>
  <tr><td>Technical Support</td><td>0.054</td><td>0.044</td><td>+0.010</td></tr>
  <tr><td>Compliance</td><td>0.096</td><td>0.093</td><td>+0.003</td></tr>
  <tr><td>Composite Score</td><td>0.91</td><td>0.90</td><td>+0.01</td></tr>
  <tr><td>Grade</td><td>F</td><td>F</td><td>—</td></tr>
</table>

### 7.2 Strength/Weakness Matrix

<table>
  <tr><th>Dimension</th><th>wafer.space Strength</th><th>GF/AMF Strength</th><th>Common Weakness</th></tr>
  <tr><td>Quality</td><td>DRC adherence, lot reject rate</td><td>Strong corporate quality systems</td><td>Yield misses on both partners</td></tr>
  <tr><td>Delivery</td><td>On-time delivery, sample quantity</td><td>Schedule adherence</td><td>—</td></tr>
  <tr><td>Cost</td><td>Payment terms, invoicing</td><td>Price stability</td><td>PPV on both partners</td></tr>
  <tr><td>Support</td><td>DRC responsiveness</td><td>PDK quality</td><td>—</td></tr>
  <tr><td>Compliance</td><td>Grant documentation</td><td>RMAP conformance</td><td>—</td></tr>
</table>

### 7.3 Trend Analysis (Quarter-over-Quarter)

<table>
  <tr><th>Quarter</th><th>wafer.space Score</th><th>GF/AMF Score</th><th>Trend</th></tr>
  <tr><td>Q1 2027</td><td>1.20 (baseline)</td><td>1.15 (baseline)</td><td>—</td></tr>
  <tr><td>Q2 2027</td><td>0.95</td><td>0.92</td><td>↓ PPV event</td></tr>
  <tr><td>Q3 2027</td><td>0.91</td><td>0.90</td><td>→ Stabilizing</td></tr>
  <tr><td>Q4 2027 (projected)</td><td>1.85</td><td>1.75</td><td>↑ Yield improvement actions</td></tr>
</table>

**Note:** The baseline scores reflect the initial MPW runs with no prior performance history. The projected Q4 2027 improvement assumes successful execution of the corrective action plans.

## Section 8: Scoring Calculation Reference

### 8.1 Weighted Score Formula

text

Composite Score = Σ (KPI Score × KPI Weight × Dimension Weight)

**Example calculation for [wafer.space](https://wafer.space/):**

- Wafer/die yield: Score 2 × KPI Weight 15% × Dimension Weight 35% = 0.105
- On-time delivery: Score 5 × KPI Weight 10% × Dimension Weight 25% = 0.125
- Purchase price variance: Score 1 × KPI Weight 8% × Dimension Weight 20% = 0.016
- **Composite Score = 0.906 → Grade F**

### 8.2 Score-to-Grade Mapping

<table>
  <tr><th>Composite Score</th><th>Grade</th><th>Color</th></tr>
  <tr><td>4.50–5.00</td><td>A</td><td>🟢</td></tr>
  <tr><td>3.50–4.49</td><td>B</td><td>🟢</td></tr>
  <tr><td>2.50–3.49</td><td>C</td><td>🟡</td></tr>
  <tr><td>1.50–2.49</td><td>D</td><td>🟠</td></tr>
  <tr><td>1.00–1.49</td><td>F</td><td>🔴</td></tr>
</table>

## Section 9: Quarterly Review Process

### 9.1 Data Collection Checklist (Weeks 1–2 of Quarter)

<table>
  <tr><th>#</th><th>Data Item</th><th>Source</th><th>Owner</th><th>Due</th></tr>
  <tr><td>1</td><td>Yield reports for all lots (RISC-V64, GPU, PTA)</td><td>Foundry yield reports</td><td>Foundry Ops</td><td>Week 1</td></tr>
  <tr><td>2</td><td>DRC iteration logs</td><td>Submission platform</td><td>Design Automation</td><td>Week 1</td></tr>
  <tr><td>3</td><td>On-time delivery metrics</td><td>Foundry portal / shipping notices</td><td>Supply Chain</td><td>Week 1</td></tr>
  <tr><td>4</td><td>PPV calculations from AP sub-ledger</td><td>AP system</td><td>Controller</td><td>Week 1</td></tr>
  <tr><td>5</td><td>Technical support ticket logs</td><td>Email / portal</td><td>Design Eng</td><td>Week 2</td></tr>
  <tr><td>6</td><td>Compliance documentation status</td><td>Grant Admin</td><td>Grant Admin</td><td>Week 2</td></tr>
  <tr><td>7</td><td>Cost per good die calculations</td><td>Yield + AP data</td><td>Controller</td><td>Week 2</td></tr>
</table>

### 9.2 Scoring & Review Meeting (Weeks 3–4)

<table>
  <tr><th>#</th><th>Activity</th><th>Owner</th><th>Output</th></tr>
  <tr><td>1</td><td>Calculate KPI scores and weighted composite</td><td>Foundry Ops</td><td>Draft scorecard</td></tr>
  <tr><td>2</td><td>Prepare comparative dashboard</td><td>FP&amp;A</td><td>Side-by-side view</td></tr>
  <tr><td>3</td><td>Review with CFO and CTO</td><td>CFO / CTO</td><td>Validated scorecard</td></tr>
  <tr><td>4</td><td>Prepare partner feedback summary</td><td>Foundry Ops</td><td>Feedback document</td></tr>
  <tr><td>5</td><td>Schedule partner review meeting</td><td>Foundry Ops</td><td>Meeting invitation</td></tr>
  <tr><td>6</td><td>Conduct partner review meeting</td><td>CFO / CTO / Partner</td><td>Meeting minutes</td></tr>
  <tr><td>7</td><td>Document corrective actions</td><td>Foundry Ops</td><td>Action plan</td></tr>
  <tr><td>8</td><td>Distribute scorecard to board (if material)</td><td>CFO</td><td>Board package</td></tr>
</table>

## Section 10: Partner Feedback & Engagement Templates

### 10.1 Quarterly Partner Review Agenda

<table>
  <tr><th>Time</th><th>Item</th><th>Presenter</th></tr>
  <tr><td>0:00–0:05</td><td>Opening and agenda</td><td>Your company</td></tr>
  <tr><td>0:05–0:15</td><td>Scorecard summary and composite score</td><td>Your company</td></tr>
  <tr><td>0:15–0:30</td><td>Quality and yield review</td><td>Partner</td></tr>
  <tr><td>0:30–0:45</td><td>Delivery and schedule review</td><td>Partner</td></tr>
  <tr><td>0:45–1:00</td><td>Cost and commercial terms review</td><td>Your company</td></tr>
  <tr><td>1:00–1:15</td><td>Technical support review</td><td>Both</td></tr>
  <tr><td>1:15–1:30</td><td>Corrective action plan and next steps</td><td>Both</td></tr>
</table>

### 10.2 Partner Feedback Template

**Partner:** [[wafer.space](https://wafer.space/) / GF/AMF]  
**Review Period:** [Quarter] [Year]  
**Composite Score:** [X.XX] — Grade: [A/B/C/D/F]

**Strengths:**

- [List 2–3 specific strengths with data]

**Areas for Improvement:**

- [List 2–3 specific improvement areas with data]

**Corrective Actions Agreed:**

<table>
  <tr><th>#</th><th>Action</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td></td><td></td><td></td></tr>
  <tr><td>2</td><td></td><td></td><td></td></tr>
</table>

**Next Review Date:** [Date]

## Section 11: Escalation Matrix

<table>
  <tr><th>Composite Score</th><th>Escalation Level</th><th>Action</th><th>Responsible</th></tr>
  <tr><td>≥ 3.5</td><td>Routine</td><td>Standard quarterly review</td><td>Foundry Ops</td></tr>
  <tr><td>2.5–3.4</td><td>Management</td><td>CFO/CTO review with partner</td><td>CFO / CTO</td></tr>
  <tr><td>1.5–2.4</td><td>Executive</td><td>CEO review; formal corrective action plan</td><td>CEO</td></tr>
  <tr><td>&lt; 1.5</td><td>Board</td><td>Board notification; qualify alternative partner</td><td>Board</td></tr>
</table>

## Section 12: Integration with Other Financial Processes

### 12.1 Link to Rolling Forecast

<table>
  <tr><th>Scorecard Dimension</th><th>Rolling Forecast Driver</th><th>Impact</th></tr>
  <tr><td>Quality &amp; Yield</td><td>Yield assumptions (RISC-V64: 95%, GPU: 90%, PTA: 85%)</td><td>Updates yield drivers in forecast</td></tr>
  <tr><td>Delivery &amp; Schedule</td><td>Foundry slot timing</td><td>Updates cash flow prepayment timing</td></tr>
  <tr><td>Cost &amp; Commercial Terms</td><td>Slot price assumptions</td><td>Updates COGS and PPV forecasts</td></tr>
  <tr><td>Technical Support</td><td>DRC iteration assumptions</td><td>Updates R&amp;D mask &amp; reticle costs</td></tr>
  <tr><td>Compliance</td><td>Grant claim eligibility</td><td>Updates grant revenue recognition</td></tr>
</table>

### 12.2 Link to Monthly Close

<table>
  <tr><th>Scorecard KPI</th><th>Monthly Close Task</th><th>Owner</th></tr>
  <tr><td>Yield variance</td><td>Calculate yield variance for each chip</td><td>Foundry Ops</td></tr>
  <tr><td>PPV</td><td>Calculate PPV on foundry invoices</td><td>Procurement</td></tr>
  <tr><td>Cost per good die</td><td>Calculate COGS per unit</td><td>Controller</td></tr>
  <tr><td>On-time delivery</td><td>Update WIP aging</td><td>Supply Chain</td></tr>
  <tr><td>DRC iterations</td><td>Track against budgeted iterations</td><td>Design Automation</td></tr>
</table>

### 12.3 Link to Board Reporting

The foundry partner scorecard feeds directly into the board-ready financial summary. The composite score and key variances (yield, PPV) are highlighted in the operational KPI section and the risk/opportunity summary.

## Section 13: Scorecard Governance

<table>
  <tr><th>Policy</th><th>Specification</th></tr>
  <tr><td>Review frequency</td><td>Quarterly, with monthly data collection</td></tr>
  <tr><td>Scorecard owner</td><td>Foundry Operations Manager</td></tr>
  <tr><td>Review participants</td><td>CFO, CTO, Foundry Ops, Design Eng, Supply Chain</td></tr>
  <tr><td>Data validation</td><td>All KPI data must be traceable to a documented source</td></tr>
  <tr><td>Partner notification</td><td>Partners receive scorecard summary at quarterly review meeting</td></tr>
  <tr><td>Corrective action tracking</td><td>All corrective actions tracked in a central log with owners and deadlines</td></tr>
  <tr><td>Scorecard retention</td><td>Retained for 7 years for audit and trend analysis</td></tr>
  <tr><td>Escalation threshold</td><td>Any composite score below 2.5 triggers executive escalation</td></tr>
  <tr><td>Baseline reset</td><td>Scorecard baseline is reset annually to reflect process maturity</td></tr>
</table>

## Section 14: Key Observations & Strategic Recommendations

### 14.1 What the Scorecard Reveals

The most important insight from this scorecard is that **both partners received failing grades (F)**, but for different reasons. [wafer.space](https://wafer.space/)'s failure is driven almost entirely by customer-controlled factors — the missed early-bird deadline and design-side yield issues. GF/AMF's failure is more balanced, reflecting both design-side DRC issues and partner-side yield challenges in the photonics process.

The scorecard should not be read as a verdict on partner quality. Instead, it should be read as a **diagnostic tool** that identifies where your company needs to improve its own processes (design freeze discipline, DRC rule integration, yield-aware design) versus where partner engagement is needed (yield improvement commitments, multi-run pricing, DRC support responsiveness).

### 14.2 Strategic Recommendations

<table>
  <tr><th>#</th><th>Recommendation</th><th>Rationale</th><th>Owner</th><th>Timeline</th></tr>
  <tr><td>1</td><td>Implement design freeze 4 weeks before slot deadline</td><td>Eliminates the single largest PPV driver ($18,000)</td><td>Program Mgmt</td><td>Immediate</td></tr>
  <tr><td>2</td><td>Integrate AMF DRC rule deck into AI design tool</td><td>Eliminates DRC overrun ($7,000 PPV)</td><td>Design Automation</td><td>Q1 2028</td></tr>
  <tr><td>3</td><td>Negotiate multi-run pricing with wafer.space</td><td>Locks in early-bird pricing for future runs</td><td>CFO</td><td>Q1 2028</td></tr>
  <tr><td>4</td><td>Execute AMF photonics DOE run</td><td>Closes PTA yield gap from 72% to 85%+</td><td>Photonics Eng</td><td>Q1 2028</td></tr>
  <tr><td>5</td><td>Establish quarterly partner review meetings</td><td>Formalizes feedback loop and accountability</td><td>Foundry Ops</td><td>Q1 2028</td></tr>
  <tr><td>6</td><td>Track cost per good die as a primary KPI</td><td>Captures compounding effect of yield on unit economics</td><td>Controller</td><td>Immediate</td></tr>
</table>

### 14.3 Scorecard Maturity Roadmap

<table>
  <tr><th>Phase</th><th>Timeline</th><th>Scorecard Evolution</th></tr>
  <tr><td>Phase 1: Baseline</td><td>Current</td><td>Establish KPI definitions, data sources, and scoring methodology</td></tr>
  <tr><td>Phase 2: Data Quality</td><td>Q1 2028</td><td>Automate data collection from foundry portals; eliminate manual spreadsheets</td></tr>
  <tr><td>Phase 3: Predictive</td><td>Q2 2028</td><td>Add leading indicators (e.g., DRC iteration trends, yield trajectory)</td></tr>
  <tr><td>Phase 4: Strategic</td><td>Q3 2028</td><td>Integrate scorecard with supplier risk assessment and multi-sourcing strategy</td></tr>
</table>

---

This foundry partner scorecard gives you a complete, data-driven framework for evaluating [wafer.space](https://wafer.space/) and GlobalFoundries/AMF against the metrics that matter most to your business: yield, delivery, cost, and compliance. The key insight is that **your company controls the largest variance drivers** — design readiness, DRC rule integration, and early-bird discipline — and the scorecard should be used as a diagnostic tool to drive internal improvement as much as partner accountability.

---

# Grant Budget vs. Actual Template: Canadian Fabless Semiconductor Company

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Reporting Basis:** Canadian GAAP (ASPE) or IFRS  
**Grant Management Standard:** Monthly reconciliation to general ledger, by budget category  
**Integration:** Directly feeds the monthly close process and rolling forecast

## Section 1: Design Principles

This template is built on the core post-award grant management principle: **reconcile budget vs. actual monthly, not at report time** — approved vs. YTD-actual vs. remaining vs. % expended vs. burn rate. A line trending past ~10% variance is the early signal to correct spending or request a modification, before the report shows it .

The template follows the reporting requirements of your primary Canadian granting agencies:

- **NRC IRAP** requires invoices to be "in arrears," for costs already incurred and paid, with copies of consultant or subcontractor claims marked "Paid in Full" . The company must maintain project records and receipts for at least **two years after completion** .
- **FABrIC** requires beneficiaries to report on all project activities, submit a final report and supporting documents within **two months** following the project end date . Eligible costs must be "engaged and paid" .
- **NSERC** uses Form 300 (Statement of Account) for annual reconciliation, signed by a designated business officer .

## Section 2: Award Header

Every grant budget vs. actual report begins with the award header. Complete this once per grant and update as amendments occur.

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Funder / Award Name</td><td>[NRC IRAP / FABrIC / NSERC / Other]</td></tr>
  <tr><td>Award / Grant ID</td><td>[Insert Agreement #]</td></tr>
  <tr><td>Award Amount</td><td>$[Total approved grant]</td></tr>
  <tr><td>Period of Performance</td><td>[Start Date] to [End Date]</td></tr>
  <tr><td>Restricted / Unrestricted</td><td>Restricted</td></tr>
  <tr><td>Reimbursement Rate</td><td>[e.g., 40% FABrIC / Varies IRAP]</td></tr>
  <tr><td>Award Manager (Owner)</td><td>[CFO / Grant Administrator]</td></tr>
  <tr><td>Records-Retention Period</td><td>7 years (per company policy; exceeds 2-year minimum)</td></tr>
  <tr><td>Reporting Frequency</td><td>[Monthly internal / Quarterly agency / Annual]</td></tr>
</table>

## Section 3: Budget vs. Actual Summary (Monthly Reconciliation)

This is the core reconciliation table. It should be updated **every month** as part of the close process. The **% Expended** column is calculated as YTD Actual ÷ Approved Budget. The **On-Pace?** column uses a simple rule: 🟢 if within ±10% of pro-rata expectations; 🟡 if 10–20% off pace; 🔴 if >20% off pace.

**As of:** [YYYY-MM-DD]  
**Reporting Period:** Month [X] of [Total Months]

<table>
  <tr><th>Budget Category</th><th>Approved Budget</th><th>Period Actual</th><th>YTD Actual</th><th>Remaining</th><th>% Expended</th><th>On-Pace?</th><th>Variance Note (explain &gt;10%)</th></tr>
  <tr><td>Personnel</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Design Engineering Labor</td><td>$600,000</td><td>$125,250</td><td>$375,750</td><td>$224,250</td><td>62.6%</td><td>🟡</td><td>Contract engineers added for GPU acceleration</td></tr>
  <tr><td>Contract Engineering</td><td>$176,000</td><td>$44,000</td><td>$132,000</td><td>$44,000</td><td>75.0%</td><td>🟡</td><td>Accelerated GPU schedule</td></tr>
  <tr><td>Subtotal Personnel</td><td>$776,000</td><td>$169,250</td><td>$507,750</td><td>$268,250</td><td>65.4%</td><td>🟡</td><td></td></tr>
  <tr><td>Direct Materials</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Foundry — wafer.space</td><td>$24,000</td><td>$6,000</td><td>$18,000</td><td>$6,000</td><td>75.0%</td><td>🟡</td><td>Standard pricing (missed early bird)</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$35,000</td><td>$0</td><td>$0</td><td>$35,000</td><td>0.0%</td><td>🔴</td><td>DRC iterations pending</td></tr>
  <tr><td>Assembly &amp; Test</td><td>$25,000</td><td>$3,000</td><td>$9,000</td><td>$16,000</td><td>36.0%</td><td>🟢</td><td>On pace</td></tr>
  <tr><td>Board BOM</td><td>$35,000</td><td>$4,200</td><td>$12,600</td><td>$22,400</td><td>36.0%</td><td>🟢</td><td>On pace</td></tr>
  <tr><td>Subtotal Direct Materials</td><td>$119,000</td><td>$13,200</td><td>$39,600</td><td>$79,400</td><td>33.3%</td><td>🟢</td><td></td></tr>
  <tr><td>Equipment</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>Lab Equipment</td><td>$15,000</td><td>$0</td><td>$15,000</td><td>$0</td><td>100.0%</td><td>🟢</td><td>Fully expended</td></tr>
  <tr><td>Subtotal Equipment</td><td>$15,000</td><td>$0</td><td>$15,000</td><td>$0</td><td>100.0%</td><td>🟢</td><td></td></tr>
  <tr><td>Other Direct Costs</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
  <tr><td>EDA Software &amp; IP</td><td>$152,000</td><td>$12,500</td><td>$37,500</td><td>$114,500</td><td>24.7%</td><td>🟢</td><td>On pace</td></tr>
  <tr><td>Mask &amp; Reticle Costs</td><td>$22,500</td><td>$7,500</td><td>$7,500</td><td>$15,000</td><td>33.3%</td><td>🟢</td><td>One run invoiced</td></tr>
  <tr><td>Prototype &amp; Test</td><td>$100,000</td><td>$8,000</td><td>$24,000</td><td>$76,000</td><td>24.0%</td><td>🟢</td><td>On pace</td></tr>
  <tr><td>PCB Development</td><td>$15,000</td><td>$0</td><td>$0</td><td>$15,000</td><td>0.0%</td><td>🔴</td><td>NRE not yet invoiced</td></tr>
  <tr><td>Subtotal Other Direct Costs</td><td>$289,500</td><td>$28,000</td><td>$69,000</td><td>$220,500</td><td>23.8%</td><td>🟢</td><td></td></tr>
  <tr><td>Total Eligible Expenditures</td><td>$1,199,500</td><td>$210,450</td><td>$631,350</td><td>$568,150</td><td>52.6%</td><td>🟡</td><td></td></tr>
</table>

**Grant Claim Calculation:**

<table>
  <tr><th>Calculation</th><th>Amount</th></tr>
  <tr><td>Total eligible expenditures (cumulative YTD)</td><td>$631,350</td></tr>
  <tr><td>Reimbursement rate (per agreement)</td><td>40%</td></tr>
  <tr><td>Eligible claim amount</td><td>$252,540</td></tr>
  <tr><td>Less: prior claims paid</td><td>($100,000)</td></tr>
  <tr><td>Current claim amount</td><td>$152,540</td></tr>
</table>

## Section 4: Monthly Variance Detail

For each line with a variance >10%, provide a written explanation. This section maps directly to the monthly close variance analysis.

### 4.1 Personnel Variance

<table>
  <tr><th>Line Item</th><th>Budget</th><th>Actual</th><th>Variance</th><th>Root Cause</th><th>Corrective Action</th></tr>
  <tr><td>Design Engineering Labor</td><td>$14,167/mo</td><td>$16,250/mo</td><td>+$2,083/mo U</td><td>AI chip design talent premium</td><td>Annual standard rate revision (Q1 2028)</td></tr>
  <tr><td>Contract Engineering</td><td>$22,000/mo</td><td>$22,000/mo</td><td>$0</td><td>—</td><td>—</td></tr>
  <tr><td>Personnel Total</td><td>$36,167/mo</td><td>$38,250/mo</td><td>+$2,083/mo U</td><td></td><td></td></tr>
</table>

### 4.2 Direct Materials Variance

<table>
  <tr><th>Line Item</th><th>Budget</th><th>Actual</th><th>Variance</th><th>Root Cause</th><th>Corrective Action</th></tr>
  <tr><td>Foundry — wafer.space</td><td>$2,000/slot</td><td>$8,000/slot</td><td>+$6,000 U</td><td>Missed early-bird deadline</td><td>Design freeze 4 weeks before deadline</td></tr>
  <tr><td>Photonics — GF/AMF</td><td>$35,000/slot</td><td>$42,000/slot</td><td>+$7,000 U</td><td>Additional DRC iterations (5 vs. 3)</td><td>Integrate AMF DRC rule deck into AI tool</td></tr>
</table>

### 4.3 Other Direct Costs Variance

<table>
  <tr><th>Line Item</th><th>Budget</th><th>Actual</th><th>Variance</th><th>Root Cause</th><th>Corrective Action</th></tr>
  <tr><td>PCB Development</td><td>$15,000</td><td>$0</td><td>−$15,000 F</td><td>NRE not yet invoiced</td><td>Monitor; expected in Q3 2028</td></tr>
  <tr><td>Mask &amp; Reticle</td><td>$7,500/run</td><td>$7,500/run</td><td>$0</td><td>—</td><td>—</td></tr>
</table>

## Section 5: Burn Rate & Runway Analysis

For multi-year grants, the burn rate analysis is critical. It shows whether you are spending at a rate that will exhaust the grant before the project is complete — or whether you will leave unspent funds on the table.

<table>
  <tr><th>Metric</th><th>Calculation</th><th>Value</th></tr>
  <tr><td>Monthly burn rate (avg)</td><td>YTD Actual ÷ Months Elapsed</td><td>$210,450 ÷ 3 = $70,150/mo</td></tr>
  <tr><td>Total grant amount</td><td>Approved budget</td><td>$1,199,500</td></tr>
  <tr><td>Remaining budget</td><td>Approved − YTD Actual</td><td>$568,150</td></tr>
  <tr><td>Months remaining</td><td>Project end − Current month</td><td>21 months</td></tr>
  <tr><td>Required monthly burn</td><td>Remaining ÷ Months remaining</td><td>$27,055/mo</td></tr>
  <tr><td>Current vs. required</td><td>Actual burn ÷ Required burn</td><td>259%</td></tr>
  <tr><td>Projected exhaustion date</td><td>Remaining ÷ Actual burn</td><td>Month 8 (of 24)</td></tr>
  <tr><td>Risk level</td><td>—</td><td>🔴 High</td></tr>
</table>

**Analysis:** The current burn rate of $70,150/month will exhaust the $1,199,500 grant in approximately **8 months**, not the planned 24 months. This is driven primarily by:

1. Higher-than-budgeted design engineering labor ($16,250 vs. $14,167)
2. Contract engineering costs ($44,000/month for 2 engineers)
3. Foundry slot pricing at standard ($8,000) rather than early bird ($2,000)

**Corrective actions required:**

- Request a no-cost extension or budget modification from the granting agency
- Reduce contract engineering headcount from 2 to 1 effective Q1 2028
- Negotiate multi-run pricing with [wafer.space](https://wafer.space/) to lock in early-bird pricing
- Delay PCB Development NRE to Q3 2028 to smooth cash flow

## Section 6: Integration with Monthly Close

This template is designed to be completed **during** the monthly close process, not after. The following table maps each section to the close checklist phases.

<table>
  <tr><th>Template Section</th><th>Close Phase</th><th>Close Task</th><th>Owner</th><th>Due</th></tr>
  <tr><td>Award Header</td><td>Pre-Close</td><td>Confirm grant agreement terms</td><td>Grant Admin</td><td>Day −3</td></tr>
  <tr><td>Budget vs. Actual Summary</td><td>Phase 5: Grant Accounting</td><td>Compile grant-funded expenditures by category</td><td>Grant Admin</td><td>Day 4</td></tr>
  <tr><td>Monthly Variance Detail</td><td>Phase 5: Grant Accounting</td><td>Reconcile grant expenditures to budget</td><td>Grant Admin</td><td>Day 4</td></tr>
  <tr><td>Burn Rate &amp; Runway</td><td>Phase 5: Grant Accounting</td><td>Calculate burn rate and project exhaustion</td><td>Controller</td><td>Day 4</td></tr>
  <tr><td>Grant Claim Calculation</td><td>Phase 5: Grant Accounting</td><td>Prepare grant claim calculation</td><td>Controller</td><td>Day 4</td></tr>
  <tr><td>Compliance Certification</td><td>Phase 10: Review &amp; Reporting</td><td>Obtain CFO signature</td><td>CFO</td><td>Day 9</td></tr>
  <tr><td>Grant Report Submission</td><td>Phase 10: Review &amp; Reporting</td><td>Submit to agency (if due)</td><td>Grant Admin</td><td>Day 10</td></tr>
</table>

### 6.1 Journal Entries Flowing from This Template

**Grant Expenditure Recognition (Monthly):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>6020 · R&amp;D – Design Engineering Labor</td><td>$125,250</td><td></td></tr>
  <tr><td>1000 · Cash – Operating</td><td></td><td>$125,250</td></tr>
</table>

**Grant Revenue Recognition (Monthly):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>2200 · Deferred Revenue</td><td>$20,833</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td></td><td>$20,833</td></tr>
</table>

**Grant Receivable (If Milestone Achieved, Not Yet Paid):**

<table>
  <tr><th>Account</th><th>Debit</th><th>Credit</th></tr>
  <tr><td>1100 · Accounts Receivable – Grant</td><td>$152,540</td><td></td></tr>
  <tr><td>4100 · Revenue – Grant Revenue</td><td></td><td>$152,540</td></tr>
</table>

## Section 7: Canadian Grant-Specific Considerations

### 7.1 NRC IRAP

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Invoice format</td><td>Must show IRAP project number and amount claimed; signed by authorized company official</td></tr>
  <tr><td>Payment proof</td><td>Consultant or subcontractor claims must be marked &quot;Paid in Full&quot;</td></tr>
  <tr><td>Invoicing frequency</td><td>&quot;In arrears,&quot; submitted monthly where possible</td></tr>
  <tr><td>Record retention</td><td>Minimum 2 years after project completion</td></tr>
  <tr><td>Revenue recognition</td><td>Restricted contributions recognized as revenue in the year related expenses are incurred</td></tr>
</table>

**IRAP-Specific Template Adjustment:** Add a column for "IRAP Project Number" on every invoice and include a "Paid in Full" attestation for subcontractor costs.

### 7.2 FABrIC

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Eligible costs</td><td>Must be &quot;engaged and paid&quot;</td></tr>
  <tr><td>Reporting</td><td>Final report and supporting documents within 2 months of project end</td></tr>
  <tr><td>Work location</td><td>All project work must be done in Canada (max 10% outside with prior written approval)</td></tr>
  <tr><td>Reimbursement</td><td>Up to 40% of eligible expenses (Fabrication Process Development) or 37% (IoT Product Development)</td></tr>
</table>

**FABrIC-Specific Template Adjustment:** Add a "Work Location" column to track that at least 90% of project work is performed in Canada.

### 7.3 NSERC

<table>
  <tr><th>Requirement</th><th>Detail</th></tr>
  <tr><td>Reconciliation</td><td>Annual Reconciliation of Active Awards for period April 1 to March 31</td></tr>
  <tr><td>Form 300</td><td>Statement of Account signed by designated business officer</td></tr>
  <tr><td>FDSR System</td><td>Financial Data Submission and Reconciliation system for university officials</td></tr>
  <tr><td>Expenditure basis</td><td>All proposed expenditures must be in Canadian dollars</td></tr>
</table>

**NSERC-Specific Template Adjustment:** Add a CAD/USD exchange rate column for any USD-denominated costs ([wafer.space](https://wafer.space/), GF/AMF).

## Section 8: Grant Modification & No-Cost Extension Tracker

When variances exceed thresholds, a budget modification or no-cost extension may be required. Track these requests here.

<table>
  <tr><th>Date Requested</th><th>Type</th><th>Reason</th><th>Prior Approval Needed?</th><th>Approved (Date)</th><th>Revised Budget Filed?</th></tr>
  <tr><td>[Date]</td><td>Budget revision</td><td>Contract engineering overrun</td><td>Yes</td><td>[Date]</td><td>☐</td></tr>
  <tr><td>[Date]</td><td>No-cost extension</td><td>PTA photonics yield delay</td><td>Yes</td><td>Pending</td><td>☐</td></tr>
  <tr><td>[Date]</td><td>Scope change</td><td>Added GPU stitching optimization</td><td>Yes</td><td>[Date]</td><td>☐</td></tr>
</table>

## Section 9: Audit Readiness Checklist

The grant budget vs. actual template is only as good as the documentation behind it. Complete this checklist quarterly.

<table>
  <tr><th>#</th><th>Item</th><th>Status</th><th>Location</th></tr>
  <tr><td>1</td><td>Executed award + all amendments/approvals on file</td><td>☐</td><td>Compliance folder</td></tr>
  <tr><td>2</td><td>Approved budget + every revision on file</td><td>☐</td><td>Compliance folder</td></tr>
  <tr><td>3</td><td>Source document for every charge (invoice / receipt / timesheet)</td><td>☐</td><td>AP system / HR</td></tr>
  <tr><td>4</td><td>Ledger reconciles to drawdowns and to reports</td><td>☐</td><td>GL</td></tr>
  <tr><td>5</td><td>All submitted reports + submission confirmations on file</td><td>☐</td><td>Compliance folder</td></tr>
  <tr><td>6</td><td>Cost-allocation methodology + indirect-rate basis documented</td><td>☐</td><td>Finance</td></tr>
  <tr><td>7</td><td>Records-retention period confirmed for this award</td><td>☐</td><td>Compliance folder</td></tr>
  <tr><td>8</td><td>Timesheets for all grant-funded personnel</td><td>☐</td><td>HR / Grant Admin</td></tr>
  <tr><td>9</td><td>Bank statements showing grant expenditures</td><td>☐</td><td>Treasury</td></tr>
  <tr><td>10</td><td>Payroll registers with grant allocation</td><td>☐</td><td>Payroll system</td></tr>
</table>

## Section 10: Multi-Year Budget vs. Actual View

For grants spanning multiple fiscal years (e.g., FABrIC 24-month projects), a multi-year view is essential. This view rolls up monthly actuals into annual and project-to-date totals.

<table>
  <tr><th>Budget Category</th><th>Year 1 Budget</th><th>Year 1 Actual</th><th>Year 2 Budget</th><th>Year 2 Actual</th><th>Project-to-Date</th><th>Total Budget</th><th>% Complete</th></tr>
  <tr><td>Personnel</td><td>$400,000</td><td>$507,750</td><td>$376,000</td><td>—</td><td>$507,750</td><td>$776,000</td><td>65.4%</td></tr>
  <tr><td>Direct Materials</td><td>$60,000</td><td>$39,600</td><td>$59,000</td><td>—</td><td>$39,600</td><td>$119,000</td><td>33.3%</td></tr>
  <tr><td>Equipment</td><td>$15,000</td><td>$15,000</td><td>$0</td><td>—</td><td>$15,000</td><td>$15,000</td><td>100.0%</td></tr>
  <tr><td>Other Direct</td><td>$150,000</td><td>$69,000</td><td>$139,500</td><td>—</td><td>$69,000</td><td>$289,500</td><td>23.8%</td></tr>
  <tr><td>Total</td><td>$625,000</td><td>$631,350</td><td>$574,500</td><td>—</td><td>$631,350</td><td>$1,199,500</td><td>52.6%</td></tr>
</table>

**Year 1 Note:** Year 1 actuals ($631,350) already exceed Year 1 budget ($625,000) by $6,350, driven entirely by personnel overruns. Year 2 budget must be adjusted downward for personnel to compensate, or a budget modification must be requested.

## Section 11: Grant Report Calendar

<table>
  <tr><th>Report</th><th>Type</th><th>Period Covered</th><th>Agency Due Date</th><th>Internal Draft</th><th>Submitted?</th><th>Confirmation on File?</th></tr>
  <tr><td>IRAP Quarterly Progress</td><td>Programmatic</td><td>Q1 2027</td><td>[Date]</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
  <tr><td>IRAP Statement of Account</td><td>Financial</td><td>Q1 2027</td><td>[Date]</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
  <tr><td>FABrIC Quarterly Claim</td><td>Financial</td><td>Q1 2027</td><td>[Date]</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
  <tr><td>FABrIC Milestone Report</td><td>Programmatic</td><td>Q1 2027</td><td>[Date]</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
  <tr><td>NSERC Form 300</td><td>Financial</td><td>Apr 2026–Mar 2027</td><td>Sep 30, 2027</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
  <tr><td>CFI Annual Report</td><td>Financial</td><td>Apr 2026–Mar 2027</td><td>Jun 15, 2027</td><td>[Date]</td><td>☐</td><td>☐</td></tr>
</table>

---

This grant budget vs. actual template gives you a complete, monthly operational framework that integrates directly with your close process, rolling forecast, and board reporting. The critical insight for your business is that **personnel costs are consuming the grant at 2.5× the required burn rate**, which will exhaust your FABrIC or IRAP funding in approximately 8 months rather than the planned 24. The template surfaces this problem **before** the agency report is due, giving you time to request a budget modification or no-cost extension.

---

# Supplier Risk Assessment Matrix: [wafer.space](https://wafer.space/) & GlobalFoundries / AMF

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Assessment Owner:** CFO / Foundry Operations  
**Review Cadence:** Quarterly (with monthly risk indicator monitoring)  
**Scoring Framework:** 5×5 Likelihood × Impact matrix with weighted composite risk index  
**Reporting Period:** Q3 2027

## Section 1: Executive Risk Dashboard

<table>
  <tr><th>Risk Category</th><th>wafer.space</th><th>GF/AMF</th><th>Combined Exposure</th><th>Trend</th><th>Board Escalation?</th></tr>
  <tr><td>Financial Health</td><td>🔴 High</td><td>🟡 Medium</td><td>Medium-High</td><td>→</td><td>Yes (wafer.space)</td></tr>
  <tr><td>Operational &amp; Yield</td><td>🟡 Medium</td><td>🔴 High</td><td>High</td><td>↑</td><td>Yes (PTA yield)</td></tr>
  <tr><td>Geopolitical &amp; Trade</td><td>🟢 Low</td><td>🟡 Medium</td><td>Medium</td><td>↑</td><td>Monitor</td></tr>
  <tr><td>Concentration &amp; Dependency</td><td>🟡 Medium</td><td>🟡 Medium</td><td>Medium</td><td>→</td><td>Monitor</td></tr>
  <tr><td>Business Continuity</td><td>🟡 Medium</td><td>🟢 Low</td><td>Medium</td><td>→</td><td>No</td></tr>
  <tr><td>Compliance &amp; Regulatory</td><td>🟢 Low</td><td>🟢 Low</td><td>Low</td><td>→</td><td>No</td></tr>
  <tr><td>Grant Eligibility</td><td>🟢 Low</td><td>🟢 Low</td><td>Low</td><td>→</td><td>No</td></tr>
  <tr><td>Overall Composite Risk</td><td>2.8 / 5.0</td><td>3.1 / 5.0</td><td>2.95 / 5.0</td><td>↑</td><td>Yes</td></tr>
</table>

**Key Finding:** The combined supplier risk profile is assessed as **Medium-High**. GF/AMF carries the highest operational risk due to the PTA photonics yield gap (72% vs. 85% standard), while [wafer.space](https://wafer.space/) carries the highest financial risk due to its early-stage venture status and revenue concentration in the MPW shuttle business model. Both risks are manageable with the mitigations outlined in this matrix.

## Section 2: Risk Scoring Framework

### 2.1 Likelihood Scale

<table>
  <tr><th>Score</th><th>Rating</th><th>Definition</th><th>Frequency</th></tr>
  <tr><td>5</td><td>Almost Certain</td><td>Expected to occur in most circumstances</td><td>&gt;80% probability in 12 months</td></tr>
  <tr><td>4</td><td>Likely</td><td>Will probably occur at some point</td><td>50–80% probability in 12 months</td></tr>
  <tr><td>3</td><td>Possible</td><td>Might occur occasionally</td><td>20–50% probability in 12 months</td></tr>
  <tr><td>2</td><td>Unlikely</td><td>Could occur but not expected</td><td>5–20% probability in 12 months</td></tr>
  <tr><td>1</td><td>Rare</td><td>May occur only in exceptional circumstances</td><td>&lt;5% probability in 12 months</td></tr>
</table>

### 2.2 Impact Scale

<table>
  <tr><th>Score</th><th>Rating</th><th>Financial Impact</th><th>Operational Impact</th><th>Strategic Impact</th></tr>
  <tr><td>5</td><td>Catastrophic</td><td>&gt;$500K or &gt;6 months delay</td><td>Production halt; no alternative</td><td>Company viability threatened</td></tr>
  <tr><td>4</td><td>Major</td><td>$200K–$500K or 3–6 months delay</td><td>Significant disruption; costly workaround</td><td>Major strategic setback</td></tr>
  <tr><td>3</td><td>Moderate</td><td>$50K–$200K or 1–3 months delay</td><td>Noticeable disruption; manageable workaround</td><td>Moderate strategic impact</td></tr>
  <tr><td>2</td><td>Minor</td><td>$10K–$50K or 2–4 weeks delay</td><td>Minor disruption; easily absorbed</td><td>Minor strategic impact</td></tr>
  <tr><td>1</td><td>Insignificant</td><td>&lt;$10K or &lt;2 weeks delay</td><td>Negligible disruption</td><td>No strategic impact</td></tr>
</table>

### 2.3 Risk Rating Matrix (5×5)

<table>
  <tr><th>Likelihood ↓ / Impact →</th><th>1 (Insignificant)</th><th>2 (Minor)</th><th>3 (Moderate)</th><th>4 (Major)</th><th>5 (Catastrophic)</th></tr>
  <tr><td>5 (Almost Certain)</td><td>5</td><td>10</td><td>15</td><td>20</td><td>25</td></tr>
  <tr><td>4 (Likely)</td><td>4</td><td>8</td><td>12</td><td>16</td><td>20</td></tr>
  <tr><td>3 (Possible)</td><td>3</td><td>6</td><td>9</td><td>12</td><td>15</td></tr>
  <tr><td>2 (Unlikely)</td><td>2</td><td>4</td><td>6</td><td>8</td><td>10</td></tr>
  <tr><td>1 (Rare)</td><td>1</td><td>2</td><td>3</td><td>4</td><td>5</td></tr>
</table>

**Risk Rating Bands:**

- **1–4:** 🟢 Low — Accept; monitor routinely
- **5–9:** 🟡 Medium — Mitigate; assign risk owner
- **10–15:** 🟠 High — Treat urgently; escalate to CFO/CTO
- **16–25:** 🔴 Critical — Escalate to Board; immediate action required

## Section 3: Risk Register — [wafer.space](https://wafer.space/)

### 3.1 Supplier Profile

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Supplier</td><td>wafer.space</td></tr>
  <tr><td>Services</td><td>GF180MCU MPW shuttle aggregation, dicing, packaging, logistics</td></tr>
  <tr><td>Chips</td><td>RISC-V64 SoC, GPU</td></tr>
  <tr><td>Annual Spend</td><td>$24,000 (projected)</td></tr>
  <tr><td>Relationship Duration</td><td>18 months</td></tr>
  <tr><td>Contract Type</td><td>Per-run purchase (no long-term agreement)</td></tr>
  <tr><td>Key Contact</td><td>Tim Ansell (founder)</td></tr>
</table>

### 3.2 Risk Register

<table>
  <tr><th>#</th><th>Risk</th><th>Category</th><th>Likelihood</th><th>Impact</th><th>Risk Score</th><th>Rating</th><th>Mitigation</th><th>Owner</th></tr>
  <tr><td>W-01</td><td>Financial instability — wafer.space is an early-stage venture; if it ceases operations, MPW shuttle access is lost</td><td>Financial Health</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td><td>Qualify alternative MPW aggregator (ChipFoundry, Europractice); maintain 6-month buffer of die inventory</td><td>CFO</td></tr>
  <tr><td>W-02</td><td>Customer concentration — wafer.space&#39;s revenue depends on a limited number of shuttle participants; loss of key customers could reduce shuttle frequency</td><td>Financial Health</td><td>4</td><td>2</td><td>8</td><td>🟡 Medium</td><td>Diversify across multiple shuttles; engage with wafer.space on customer diversification</td><td>CFO</td></tr>
  <tr><td>W-03</td><td>Key person risk — Tim Ansell is the driving force behind wafer.space; his departure could disrupt operations</td><td>Operational</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td><td>Maintain direct relationships with GF and alternative aggregators; document all technical interactions</td><td>Foundry Ops</td></tr>
  <tr><td>W-04</td><td>Shuttle cancellation — if minimum participant threshold is not met, a shuttle run may be cancelled, delaying fabrication by a full quarter</td><td>Operational</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Purchase slots early; monitor participant counts; maintain contingency for full-mask run</td><td>Foundry Ops</td></tr>
  <tr><td>W-05</td><td>Yield underperformance — wafer.space&#39;s yield performance may vary; RISC-V64 yield at 88% vs. 95% standard</td><td>Operational</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Design margin; yield-aware design rules; collaborate on process optimization</td><td>Design Eng</td></tr>
  <tr><td>W-06</td><td>IP protection in MPW — multi-project wafers raise IP sensitivity concerns; other participants&#39; designs share the same reticle</td><td>Compliance</td><td>2</td><td>4</td><td>8</td><td>🟡 Medium</td><td>Execute NDAs; implement design watermarking; limit GDS sharing</td><td>Legal</td></tr>
  <tr><td>W-07</td><td>Late DRC or tape-out — missing the shuttle deadline defers fabrication by a full quarter</td><td>Operational</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Design freeze 4 weeks before deadline; pre-validate DRC</td><td>Program Mgmt</td></tr>
  <tr><td>W-08</td><td>Pricing escalation — slot pricing has increased from $2,000 (early bird) to $8,000 (standard); future runs may see further increases</td><td>Commercial</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Negotiate multi-run pricing; budget at standard pricing</td><td>CFO</td></tr>
  <tr><td>W-09</td><td>Logistics and packaging risk — dicing, packaging, and shipping are handled by wafer.space; errors could damage or lose die</td><td>Operational</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td><td>Require shipping insurance; inspect die on receipt; document discrepancies</td><td>Supply Chain</td></tr>
  <tr><td>W-10</td><td>Technology roadmap risk — wafer.space&#39;s roadmap may not support your future node requirements (e.g., moving beyond 180nm)</td><td>Strategic</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td><td>Monitor wafer.space roadmap; identify alternative foundry partners for advanced nodes</td><td>CTO</td></tr>
</table>

**[wafer.space](https://wafer.space/) Composite Risk Score:** 2.8 / 5.0 — **Medium-High**

## Section 4: Risk Register — GlobalFoundries / AMF

### 4.1 Supplier Profile

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Supplier</td><td>GlobalFoundries / Advanced Micro Foundry (AMF)</td></tr>
  <tr><td>Services</td><td>Silicon photonics MPW shuttle, DRC support, PDK access</td></tr>
  <tr><td>Chips</td><td>PTA (Photonics Tensor Accelerator)</td></tr>
  <tr><td>Annual Spend</td><td>$35,000–$42,000 (projected)</td></tr>
  <tr><td>Relationship Duration</td><td>12 months</td></tr>
  <tr><td>Contract Type</td><td>Per-run purchase (quote-based)</td></tr>
  <tr><td>Parent Company</td><td>GlobalFoundries Inc. (Nasdaq: GFS)</td></tr>
</table>

### 4.2 Risk Register

<table>
  <tr><th>#</th><th>Risk</th><th>Category</th><th>Likelihood</th><th>Impact</th><th>Risk Score</th><th>Rating</th><th>Mitigation</th><th>Owner</th></tr>
  <tr><td>G-01</td><td>Photonics yield underperformance — PTA yield at 72% vs. 85% standard; grating coupler insertion loss is the primary driver</td><td>Operational</td><td>4</td><td>4</td><td>16</td><td>🔴 Critical</td><td>Execute AMF DOE run ($45,000, Q1 2028); integrate AMF DRC rules into AI design tool</td><td>Photonics Eng</td></tr>
  <tr><td>G-02</td><td>DRC iteration overrun — 5 DRC iterations vs. 3-iteration limit; each additional iteration costs ~$3,500</td><td>Operational</td><td>4</td><td>3</td><td>12</td><td>🟠 High</td><td>Pre-validate photonic layouts against AMF rules; integrate DRC rule deck into AI tool</td><td>Design Automation</td></tr>
  <tr><td>G-03</td><td>AMF integration risk — GF acquired AMF in November 2025; integration may disrupt service levels, DRC support, and PDK development</td><td>Operational</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Monitor integration milestones; maintain direct AMF relationships; track GF quarterly earnings</td><td>Foundry Ops</td></tr>
  <tr><td>G-04</td><td>Capacity constraints — GF&#39;s Singapore facility utilization exceeds 90%; equipment lead times are constraining photonics capacity expansion</td><td>Operational</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td><td>Book slots early; negotiate capacity commitments; monitor GF capacity announcements</td><td>Foundry Ops</td></tr>
  <tr><td>G-05</td><td>Financial health — GF&#39;s free cash flow growth declined 93.33% in FY 2025; Piotroski F-Score of 6–7 (above average)</td><td>Financial Health</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td><td>Monitor quarterly; no immediate concern given GF&#39;s $1.5B credit facility and strong gross margins (27.8%)</td><td>CFO</td></tr>
  <tr><td>G-06</td><td>Single-source dependency — PTA photonics is sole-sourced to GF/AMF; no qualified alternative photonics foundry</td><td>Concentration</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td><td>Qualify alternative photonics foundries (CompoundTek, Tower Semiconductor); explore open-access GF/SMART Photonics service</td><td>CTO</td></tr>
  <tr><td>G-07</td><td>Geopolitical — Singapore — Singapore is a stable jurisdiction but is exposed to US-China trade tensions and regional supply chain disruption</td><td>Geopolitical</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td><td>Monitor US-China trade policy; maintain buffer inventory of PTA chips</td><td>CFO</td></tr>
  <tr><td>G-08</td><td>Indium phosphide (InP) substrate supply — InP substrate availability is becoming a critical risk due to Chinese export controls; IQE has warned of supply uncertainty</td><td>Supply Chain</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td><td>Monitor InP supply; explore alternative photonics platforms (silicon nitride); engage GF on substrate sourcing</td><td>Photonics Eng</td></tr>
  <tr><td>G-09</td><td>Open-access service delay — GF/SMART Photonics open-access service is targeted for H2 2027; delays would limit access to integrated InP lasers</td><td>Strategic</td><td>3</td><td>2</td><td>6</td><td>🟡 Medium</td><td>Monitor service launch; maintain contingency for external laser integration</td><td>CTO</td></tr>
  <tr><td>G-10</td><td>PDK quality and support — photonics PDK may have gaps or documentation issues; DRC support responsiveness is 48–72 hours</td><td>Operational</td><td>3</td><td>2</td><td>6</td><td>🟡 Medium</td><td>Document all PDK issues; escalate through GF account manager; budget for additional DRC iterations</td><td>Design Eng</td></tr>
</table>

**GF/AMF Composite Risk Score:** 3.1 / 5.0 — **High**

## Section 5: Cross-Supplier Comparative Analysis

### 5.1 Risk Dimension Comparison

<table>
  <tr><th>Risk Dimension</th><th>wafer.space Score</th><th>GF/AMF Score</th><th>Higher Risk</th><th>Commentary</th></tr>
  <tr><td>Financial Health</td><td>4.0</td><td>3.0</td><td>wafer.space</td><td>wafer.space is an early-stage venture; GF is a publicly traded company with $1.5B credit facility</td></tr>
  <tr><td>Operational &amp; Yield</td><td>3.3</td><td>4.5</td><td>GF/AMF</td><td>PTA photonics yield gap is the single largest risk in the portfolio</td></tr>
  <tr><td>Geopolitical &amp; Trade</td><td>1.5</td><td>3.0</td><td>GF/AMF</td><td>Singapore exposure; InP substrate supply concentration in China</td></tr>
  <tr><td>Concentration &amp; Dependency</td><td>3.0</td><td>3.5</td><td>GF/AMF</td><td>Both are effectively single-source for their respective processes</td></tr>
  <tr><td>Business Continuity</td><td>2.5</td><td>2.0</td><td>wafer.space</td><td>wafer.space has no formal BCP; GF has strong corporate BCP</td></tr>
  <tr><td>Compliance &amp; Regulatory</td><td>2.0</td><td>1.5</td><td>wafer.space</td><td>MPW IP protection is a concern; GF has mature compliance systems</td></tr>
  <tr><td>Grant Eligibility</td><td>1.5</td><td>1.5</td><td>—</td><td>Both partners are grant-eligible; documentation is adequate</td></tr>
</table>

### 5.2 Risk Heat Map

<table>
  <tr><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Score</th><th>Quadrant</th></tr>
  <tr><td>G-01: PTA photonics yield</td><td>4</td><td>4</td><td>16</td><td>🔴 Critical</td></tr>
  <tr><td>W-01: wafer.space financial instability</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td></tr>
  <tr><td>G-02: DRC iteration overrun</td><td>4</td><td>3</td><td>12</td><td>🟠 High</td></tr>
  <tr><td>G-06: Single-source photonics dependency</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td></tr>
  <tr><td>G-08: InP substrate supply</td><td>3</td><td>4</td><td>12</td><td>🟠 High</td></tr>
  <tr><td>W-04: Shuttle cancellation</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>W-05: RISC-V64 yield underperformance</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>W-07: Late DRC or tape-out</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>W-08: Pricing escalation</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>G-03: AMF integration risk</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>G-04: Capacity constraints</td><td>3</td><td>3</td><td>9</td><td>🟡 Medium</td></tr>
  <tr><td>W-02: Customer concentration</td><td>4</td><td>2</td><td>8</td><td>🟡 Medium</td></tr>
  <tr><td>W-06: IP protection in MPW</td><td>2</td><td>4</td><td>8</td><td>🟡 Medium</td></tr>
  <tr><td>W-03: Key person risk</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>G-05: GF financial health</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>G-07: Singapore geopolitical</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>G-09: Open-access service delay</td><td>3</td><td>2</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>G-10: PDK quality and support</td><td>3</td><td>2</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>W-09: Logistics and packaging</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td></tr>
  <tr><td>W-10: Technology roadmap</td><td>2</td><td>3</td><td>6</td><td>🟡 Medium</td></tr>
</table>

**Portfolio Risk Distribution:**

- 🔴 Critical: 1 risk (G-01)
- 🟠 High: 4 risks (W-01, G-02, G-06, G-08)
- 🟡 Medium: 15 risks
- 🟢 Low: 0 risks

## Section 6: Risk Mitigation Action Plan

### 6.1 Critical and High Priority Risks

<table>
  <tr><th>#</th><th>Risk</th><th>Action</th><th>Investment</th><th>Timeline</th><th>Owner</th><th>Success Metric</th></tr>
  <tr><td>1</td><td>G-01: PTA yield</td><td>Execute AMF photonics DOE run</td><td>$45,000</td><td>Q1 2028</td><td>Photonics Eng</td><td>Yield ≥ 85%</td></tr>
  <tr><td>2</td><td>G-02: DRC overrun</td><td>Integrate AMF DRC rule deck into AI design tool</td><td>$15,000 (engineering time)</td><td>Q1 2028</td><td>Design Automation</td><td>≤ 3 DRC iterations</td></tr>
  <tr><td>3</td><td>G-06: Single-source photonics</td><td>Qualify alternative photonics foundry (CompoundTek, Tower)</td><td>$25,000 (evaluation)</td><td>Q2 2028</td><td>CTO</td><td>Qualified second source</td></tr>
  <tr><td>4</td><td>G-08: InP substrate supply</td><td>Monitor InP supply; explore silicon nitride alternative</td><td>$10,000 (study)</td><td>Q2 2028</td><td>Photonics Eng</td><td>Alternative platform identified</td></tr>
  <tr><td>5</td><td>W-01: wafer.space financial health</td><td>Qualify alternative MPW aggregator (ChipFoundry)</td><td>$5,000 (evaluation)</td><td>Q1 2028</td><td>Foundry Ops</td><td>Alternative qualified</td></tr>
</table>

### 6.2 Medium Priority Risks

<table>
  <tr><th>#</th><th>Risk</th><th>Action</th><th>Timeline</th><th>Owner</th></tr>
  <tr><td>6</td><td>W-04: Shuttle cancellation</td><td>Monitor participant counts; purchase slots early</td><td>Ongoing</td><td>Foundry Ops</td></tr>
  <tr><td>7</td><td>W-05: RISC-V64 yield</td><td>Enhance AI verification with formal CDC checks</td><td>Run 4</td><td>Design Eng</td></tr>
  <tr><td>8</td><td>W-07: Late tape-out</td><td>Implement design freeze 4 weeks before deadline</td><td>Immediate</td><td>Program Mgmt</td></tr>
  <tr><td>9</td><td>W-08: Pricing escalation</td><td>Negotiate multi-run pricing with wafer.space</td><td>Q1 2028</td><td>CFO</td></tr>
  <tr><td>10</td><td>G-03: AMF integration</td><td>Monitor GF integration milestones</td><td>Quarterly</td><td>Foundry Ops</td></tr>
  <tr><td>11</td><td>G-04: Capacity constraints</td><td>Book photonics slots 2 quarters in advance</td><td>Ongoing</td><td>Foundry Ops</td></tr>
  <tr><td>12</td><td>W-06: IP protection</td><td>Execute NDAs; implement design watermarking</td><td>Immediate</td><td>Legal</td></tr>
</table>

## Section 7: Contingency Plans

### 7.1 [wafer.space](https://wafer.space/) Contingency — If Supplier Fails

<table>
  <tr><th>Scenario</th><th>Trigger</th><th>Contingency</th><th>Cost Impact</th><th>Timeline Impact</th></tr>
  <tr><td>Shuttle cancellation</td><td>Participant threshold not met</td><td>Transfer design to next scheduled run</td><td>$0 (slot transferred)</td><td>+3 months</td></tr>
  <tr><td>Financial collapse</td><td>Supplier ceases operations</td><td>Transfer to ChipFoundry or Europractice</td><td>+$6,000 (standard pricing)</td><td>+2–4 months</td></tr>
  <tr><td>Key person departure</td><td>Tim Ansell leaves</td><td>Direct engagement with GF; use alternative aggregator</td><td>+$5,000</td><td>+1–2 months</td></tr>
  <tr><td>Quality failure</td><td>Die yield below 70%</td><td>Escalate; request re-run; qualify alternative</td><td>+$8,000</td><td>+3 months</td></tr>
</table>

### 7.2 GF/AMF Contingency — If Supplier Fails

<table>
  <tr><th>Scenario</th><th>Trigger</th><th>Contingency</th><th>Cost Impact</th><th>Timeline Impact</th></tr>
  <tr><td>Photonics yield remains &lt;75%</td><td>DOE run fails to improve yield</td><td>Switch PTA design to silicon nitride platform or external laser integration</td><td>+$50,000 (redesign)</td><td>+6 months</td></tr>
  <tr><td>DRC support inadequate</td><td>Repeated DRC overruns</td><td>Engage third-party photonics design service (e.g., CompoundTek)</td><td>+$25,000</td><td>+2 months</td></tr>
  <tr><td>Capacity unavailable</td><td>No slots available for 2+ quarters</td><td>Qualify Tower Semiconductor photonics platform</td><td>+$40,000 (NRE)</td><td>+4 months</td></tr>
  <tr><td>Geopolitical disruption</td><td>Singapore supply chain disrupted</td><td>Maintain 6-month buffer of PTA chips; explore domestic NRC-CPFC foundry</td><td>+$30,000 (inventory)</td><td>+1 month</td></tr>
  <tr><td>AMF integration fails</td><td>Service levels degrade post-acquisition</td><td>Direct engagement with GF corporate; escalate to account manager</td><td>$0</td><td>Variable</td></tr>
</table>

## Section 8: Risk Monitoring Dashboard

### 8.1 Monthly Risk Indicator Tracking

<table>
  <tr><th>Risk Indicator</th><th>Data Source</th><th>Green</th><th>Amber</th><th>Red</th><th>Current</th></tr>
  <tr><td>wafer.space shuttle participant count</td><td>wafer.space portal</td><td>≥ 10</td><td>5–9</td><td>&lt; 5</td><td>🟢</td></tr>
  <tr><td>wafer.space DRC iteration count</td><td>Submission platform</td><td>≤ 2</td><td>3</td><td>&gt; 3</td><td>🟢</td></tr>
  <tr><td>RISC-V64 SoC yield</td><td>Foundry yield report</td><td>≥ 95%</td><td>90–94%</td><td>&lt; 90%</td><td>🟡 (88%)</td></tr>
  <tr><td>GPU yield</td><td>Foundry yield report</td><td>≥ 90%</td><td>85–89%</td><td>&lt; 85%</td><td>🔴 (78%)</td></tr>
  <tr><td>PTA photonics yield</td><td>GF/AMF yield report</td><td>≥ 85%</td><td>75–84%</td><td>&lt; 75%</td><td>🔴 (72%)</td></tr>
  <tr><td>GF/AMF DRC iterations</td><td>Submission platform</td><td>≤ 3</td><td>4</td><td>&gt; 4</td><td>🔴 (5)</td></tr>
  <tr><td>GF Singapore capacity utilization</td><td>Public disclosures</td><td>&lt; 80%</td><td>80–90%</td><td>&gt; 90%</td><td>🔴 (&gt;90%)</td></tr>
  <tr><td>InP substrate availability</td><td>Industry news</td><td>Stable</td><td>Tightening</td><td>Constrained</td><td>🟡 (Tightening)</td></tr>
  <tr><td>wafer.space financial news</td><td>News monitoring</td><td>No concerns</td><td>Minor concerns</td><td>Material concerns</td><td>🟢</td></tr>
  <tr><td>GF financial health (Piotroski F-Score)</td><td>Public filings</td><td>≥ 7</td><td>5–6</td><td>&lt; 5</td><td>🟡 (6–7)</td></tr>
</table>

### 8.2 Quarterly Risk Review Agenda

<table>
  <tr><th>Time</th><th>Item</th><th>Presenter</th></tr>
  <tr><td>0:00–0:10</td><td>Risk dashboard review</td><td>Foundry Ops</td></tr>
  <tr><td>0:10–0:25</td><td>Critical/High risk deep-dive</td><td>Risk owners</td></tr>
  <tr><td>0:25–0:40</td><td>Mitigation progress update</td><td>Action owners</td></tr>
  <tr><td>0:40–0:50</td><td>New/emerging risks</td><td>All</td></tr>
  <tr><td>0:50–1:00</td><td>Risk appetite reassessment</td><td>CFO</td></tr>
</table>

## Section 9: Board Escalation Protocol

### 9.1 Escalation Triggers

<table>
  <tr><th>Trigger</th><th>Escalation Level</th><th>Response Time</th></tr>
  <tr><td>Any risk score ≥ 16 (Critical)</td><td>Board notification</td><td>Within 5 business days</td></tr>
  <tr><td>Two or more risks ≥ 12 (High)</td><td>Board notification</td><td>Within 10 business days</td></tr>
  <tr><td>Supplier financial health downgrade</td><td>CFO/CEO review</td><td>Within 5 business days</td></tr>
  <tr><td>Yield below 70% for any chip</td><td>CTO/CEO review</td><td>Immediate</td></tr>
  <tr><td>Supplier ceases operations</td><td>Emergency Board meeting</td><td>Within 48 hours</td></tr>
  <tr><td>Geopolitical disruption affecting supply</td><td>Board notification</td><td>Within 5 business days</td></tr>
</table>

### 9.2 Board Risk Summary Template

**Quarterly Supplier Risk Summary — [Quarter] [Year]**

<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>Total risks identified</td><td>20</td></tr>
  <tr><td>Critical risks</td><td>1</td></tr>
  <tr><td>High risks</td><td>4</td></tr>
  <tr><td>Medium risks</td><td>15</td></tr>
  <tr><td>Low risks</td><td>0</td></tr>
  <tr><td>Risks mitigated this quarter</td><td>3</td></tr>
  <tr><td>Risks escalated this quarter</td><td>1 (G-01)</td></tr>
  <tr><td>Composite supplier risk score</td><td>2.95 / 5.0</td></tr>
  <tr><td>Trend vs. prior quarter</td><td>↑ Increasing</td></tr>
</table>

**Board Action Requested:** Approve $45,000 for AMF photonics DOE run (Q1 2028) to address Critical risk G-01.

## Section 10: Risk Governance

<table>
  <tr><th>Policy</th><th>Specification</th></tr>
  <tr><td>Assessment frequency</td><td>Full risk assessment quarterly; monthly risk indicator monitoring</td></tr>
  <tr><td>Risk owner</td><td>Each risk assigned a named owner responsible for mitigation</td></tr>
  <tr><td>Scoring calibration</td><td>Scoring calibrated annually against industry benchmarks</td></tr>
  <tr><td>Escalation threshold</td><td>Any risk score ≥ 12 triggers CFO/CTO review; ≥ 16 triggers Board notification</td></tr>
  <tr><td>Mitigation tracking</td><td>All mitigations tracked with owners, timelines, and success metrics</td></tr>
  <tr><td>Supplier notification</td><td>Suppliers are informed of material risks affecting the relationship</td></tr>
  <tr><td>Documentation</td><td>Risk register, assessments, and mitigations retained for 7 years</td></tr>
  <tr><td>Board reporting</td><td>Quarterly risk summary included in board package</td></tr>
</table>

## Section 11: Key Observations & Strategic Recommendations

### 11.1 What the Risk Matrix Reveals

The most critical finding is that **GF/AMF photonics yield (G-01) is the single largest risk in the portfolio**, with a score of 16 (Critical). This risk has both high likelihood (yield is currently 72% vs. 85% standard) and high impact (yield directly drives unit economics and gross margin). The $45,000 AMF DOE run is the highest-ROI mitigation available.

The second most significant finding is that **[wafer.space](https://wafer.space/)'s financial health (W-01)** carries a High risk rating. [wafer.space](https://wafer.space/) is an early-stage venture, and if it ceases operations, you lose access to the GF180MCU MPW shuttle. The mitigation — qualifying ChipFoundry or Europractice as an alternative aggregator — is low-cost and should be prioritized.

The third finding is the **single-source dependency on GF/AMF for photonics (G-06)** and the **InP substrate supply risk (G-08)** . Both are High risks that require strategic action: qualifying alternative photonics foundries and exploring alternative photonic platforms.

### 11.2 Strategic Recommendations

<table>
  <tr><th>#</th><th>Recommendation</th><th>Rationale</th><th>Investment</th><th>Timeline</th></tr>
  <tr><td>1</td><td>Approve AMF photonics DOE run</td><td>Addresses Critical risk G-01; highest-ROI mitigation</td><td>$45,000</td><td>Q1 2028</td></tr>
  <tr><td>2</td><td>Qualify alternative MPW aggregator</td><td>Addresses High risk W-01; low-cost insurance</td><td>$5,000</td><td>Q1 2028</td></tr>
  <tr><td>3</td><td>Integrate AMF DRC rule deck</td><td>Addresses High risk G-02; eliminates $7,000/run PPV</td><td>$15,000</td><td>Q1 2028</td></tr>
  <tr><td>4</td><td>Evaluate alternative photonics foundry</td><td>Addresses High risk G-06; reduces single-source dependency</td><td>$25,000</td><td>Q2 2028</td></tr>
  <tr><td>5</td><td>Monitor InP substrate supply</td><td>Addresses High risk G-08; early warning system</td><td>$10,000</td><td>Q2 2028</td></tr>
  <tr><td>6</td><td>Negotiate multi-run pricing</td><td>Addresses Medium risk W-08; locks in early-bird pricing</td><td>$0</td><td>Q1 2028</td></tr>
</table>

### 11.3 Risk Appetite Statement

The company's risk appetite for supplier-related risks is **moderate**. We accept operational risks that are within our control (design readiness, DRC compliance, yield optimization) but require mitigation for risks that threaten supply continuity or financial viability. No single supplier should represent more than 60% of any critical input; both [wafer.space](https://wafer.space/) and GF/AMF currently exceed this threshold for their respective processes, which is why the mitigation actions in this matrix are essential.

## Section 12: Integration with Other Financial Processes

<table>
  <tr><th>Risk Matrix Output</th><th>Downstream Process</th><th>Integration Point</th></tr>
  <tr><td>Risk scores and ratings</td><td>Rolling forecast</td><td>Risk-adjusted yield assumptions</td></tr>
  <tr><td>Mitigation investments</td><td>Grant budget vs. actual</td><td>DOE run ($45K) as eligible grant cost</td></tr>
  <tr><td>Contingency cost estimates</td><td>Cash flow forecast</td><td>Scenario planning for supplier failure</td></tr>
  <tr><td>Risk indicators</td><td>Monthly close checklist</td><td>Foundry partner scorecard</td></tr>
  <tr><td>Board escalation items</td><td>Board-ready financial summary</td><td>Operational KPI section</td></tr>
  <tr><td>Grant eligibility risks</td><td>Grant application tracker</td><td>FABrIC/IRAP compliance documentation</td></tr>
</table>

---

This supplier risk assessment matrix gives you a complete, data-driven framework for evaluating geopolitical, financial, and operational risks across your [wafer.space](https://wafer.space/) and GF/AMF partnerships. The critical insight is that **PTA photonics yield (G-01) is a Critical risk requiring immediate Board attention**, and the **$45,000 AMF DOE run is the single highest-ROI mitigation available**. The matrix also reveals that your supplier concentration risk is higher than ideal — both partners are effectively single-source for their respective processes — and qualifying alternative suppliers should be a strategic priority for 2028.

---

# Multi-Source Qualification Roadmap: [wafer.space](https://wafer.space/) & GF/AMF Alternative Partners

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Roadmap Owner:** CFO / Foundry Operations  
**Review Cadence:** Quarterly progress review; annual strategy refresh  
**Planning Horizon:** 18 months (Q4 2027 – Q2 2029)

## Section 1: Purpose & Scope

### 1.1 Why Multi-Source Qualification Matters

Your current supplier risk assessment identified two High-priority risks that directly threaten supply continuity:

- **W-01: [wafer.space](https://wafer.space/) financial instability** — Early-stage venture; loss of MPW shuttle access would delay RISC-V64 SoC and GPU fabrication by 3–6 months.
- **G-06: Single-source photonics dependency** — GF/AMF is the sole qualified source for PTA photonics; no alternative exists today.

Multi-source qualification reduces manufacturing risk by ensuring multiple foundry partners can produce equivalent designs. Fabless companies switching foundries must run several prototype wafer fabrications, with significant mask/reticle, wafer, and test costs. The Semiconductor Quality Benchmark Consortium has identified multi-source fab qualification as an industry priority, with members comparing strategies for technology transfer, risk assessment, and qualification planning to demonstrate equivalent manufacturing capability across multiple fabs.

### 1.2 Scope of This Roadmap

<table>
  <tr><th>Chip</th><th>Primary Source</th><th>Alternative Candidates</th><th>Priority</th></tr>
  <tr><td>RISC-V64 SoC</td><td>wafer.space (GF180MCU, 180nm)</td><td>ChipFoundry (SKY130), Europractice (GF 180nm), MOSIS (GF)</td><td>High</td></tr>
  <tr><td>GPU</td><td>wafer.space (GF180MCU, 180nm)</td><td>ChipFoundry (SKY130), Europractice (GF 180nm), MOSIS (GF)</td><td>High</td></tr>
  <tr><td>PTA Photonics</td><td>GF/AMF (silicon photonics)</td><td>CompoundTek (8&quot; SiPho), Tower Semiconductor (PH18M), AIM Photonics (300mm SiPho)</td><td>Critical</td></tr>
</table>

### 1.3 Guiding Principles

- **Design portability first:** Every design should be portable to at least one alternative process with minimal redesign.
- **Cost-gated qualification:** Only proceed to full qualification if the alternative offers comparable cost-per-good-die economics.
- **Grant-compatible:** All qualified alternatives must support FABrIC, NRC IRAP, or NSERC grant eligibility.
- **Phased investment:** Stage-gate the investment; no full commitment without a successful prototype run.

## Section 2: Multi-Source Qualification Strategy

### 2.1 Qualification Tiers

<table>
  <tr><th>Tier</th><th>Definition</th><th>Investment</th><th>Timeline</th><th>Output</th></tr>
  <tr><td>Tier 1: Desktop Assessment</td><td>Evaluate supplier&#39;s technical capability, quality certifications, financial stability, and capacity through documentation review</td><td>$5,000–$10,000 (internal time)</td><td>1–2 months</td><td>Qualified candidate list</td></tr>
  <tr><td>Tier 2: Process Feasibility</td><td>Run a test chip or shared MPW shuttle to verify process compatibility</td><td>$15,000–$50,000</td><td>3–6 months</td><td>Feasibility report</td></tr>
  <tr><td>Tier 3: Design Port</td><td>Port one design (RISC-V64 SoC or PTA) to the alternative process</td><td>$30,000–$80,000</td><td>6–12 months</td><td>Qualified design</td></tr>
  <tr><td>Tier 4: Production Qualification</td><td>Controlled introduction into production with enhanced monitoring</td><td>$50,000–$100,000</td><td>12–18 months</td><td>Dual-sourced production</td></tr>
</table>

### 2.2 Qualification Decision Matrix

<table>
  <tr><th>Criterion</th><th>Weight</th><th>Scoring Guide</th></tr>
  <tr><td>Process compatibility</td><td>30%</td><td>5 = identical process node; 1 = major redesign required</td></tr>
  <tr><td>Cost per good die</td><td>25%</td><td>5 = ≤ current cost; 1 = &gt; 200% current cost</td></tr>
  <tr><td>Schedule availability</td><td>15%</td><td>5 = monthly shuttles; 1 = annual shuttles</td></tr>
  <tr><td>Technical support quality</td><td>10%</td><td>5 = dedicated FAE; 1 = email-only support</td></tr>
  <tr><td>Financial stability</td><td>10%</td><td>5 = public company; 1 = early-stage startup</td></tr>
  <tr><td>Grant eligibility</td><td>5%</td><td>5 = FABrIC/IRAP eligible; 1 = not eligible</td></tr>
  <tr><td>IP protection</td><td>5%</td><td>5 = strong NDAs and IP framework; 1 = unclear</td></tr>
</table>

## Section 3: Candidate Supplier Profiles

### 3.1 RISC-V64 SoC & GPU — Alternative 180nm/130nm MPW Aggregators

#### Candidate A: ChipFoundry (chipIgnite)

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>chipIgnite MPW shuttle (SKY130 130nm)</td></tr>
  <tr><td>Heritage</td><td>Founded by ex-Efabless leadership team</td></tr>
  <tr><td>Shuttle Schedule</td><td>2026: May 13, September 16, December TBD (3 shuttles)</td></tr>
  <tr><td>Price</td><td>$14,950 per tapeout, including 100 QFN packaged parts</td></tr>
  <tr><td>Process</td><td>SKY130 (130nm), not GF180MCU</td></tr>
  <tr><td>Design Portability</td><td>Requires porting from GF180MCU to SKY130</td></tr>
  <tr><td>Grant Eligibility</td><td>Not directly FABrIC-eligible; may qualify via partner</td></tr>
  <tr><td>Key Advantage</td><td>Continuity with Efabless ecosystem; Caravel SoC template available</td></tr>
</table>

**Assessment:** ChipFoundry is the strongest immediate alternative for RISC-V64 SoC and GPU. The SKY130 process is a mature open-source PDK, and the Caravel SoC template provides a proven reference design. The $14,950 price point is higher than [wafer.space](https://wafer.space/)'s early-bird $2,000 but competitive with standard $8,000 pricing. **Primary risk:** Process migration from GF180MCU to SKY130 requires design porting.

#### Candidate B: Europractice

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>Multi-project wafer (MPW) aggregation across 90+ technologies</td></tr>
  <tr><td>Heritage</td><td>Founded by EU in 1995; funded through September 2028</td></tr>
  <tr><td>GF Access</td><td>Offers GF 180nm MCU open-source access through Fraunhofer IIS</td></tr>
  <tr><td>Price</td><td>Discounted (academic/EU) and Standard pricing</td></tr>
  <tr><td>Process</td><td>GF 180nm MCU available</td></tr>
  <tr><td>Grant Eligibility</td><td>EU-funded; Canadian companies may qualify at standard pricing</td></tr>
  <tr><td>Key Advantage</td><td>Direct GF180MCU access without process porting</td></tr>
</table>

**Assessment:** Europractice is the strongest alternative for maintaining GF180MCU compatibility. Since it offers the same process as [wafer.space](https://wafer.space/), no design porting is required. However, Canadian companies may not qualify for discounted academic pricing, and the EU-based coordination may add logistics complexity.

#### Candidate C: MOSIS 2.0

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>MPW aggregation; strategic value-added partner with GlobalFoundries</td></tr>
  <tr><td>Heritage</td><td>Pioneered MPW in 1981; 40+ year legacy</td></tr>
  <tr><td>GF Access</td><td>Direct access to GF FinFET and FD-SOI processes, plus shared shuttle runs</td></tr>
  <tr><td>Process</td><td>Broad portfolio including GF nodes</td></tr>
  <tr><td>Key Advantage</td><td>US-based; strong defense/research customer base</td></tr>
  <tr><td>Grant Eligibility</td><td>US-focused; Canadian eligibility unclear</td></tr>
</table>

**Assessment:** MOSIS 2.0 is a strong long-term partner, particularly if you expand beyond 180nm to advanced nodes. The GF partnership creates a pathway from prototyping to production. However, Canadian grant eligibility is uncertain, and the US-centric focus may not align with your FABrIC/IRAP strategy.

### 3.2 PTA Photonics — Alternative Silicon Photonics Foundries

#### Candidate A: CompoundTek

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>Dedicated 8&quot; silicon photonics foundry</td></tr>
  <tr><td>Process</td><td>Full reticle or MPW; &lt;2 months cycle time</td></tr>
  <tr><td>Capabilities</td><td>Active and passive components; germanium photodetectors; silicon nitride waveguides</td></tr>
  <tr><td>MPW Program</td><td>Regular MPW shuttles; 2019–2020 schedule published</td></tr>
  <tr><td>Key Advantage</td><td>Dedicated photonics fab (not a shared CMOS line)</td></tr>
  <tr><td>Grant Eligibility</td><td>Singapore-based; not Canadian grant-eligible</td></tr>
</table>

**Assessment:** CompoundTek is the strongest alternative for PTA photonics. It operates a dedicated 8" silicon photonics foundry with active and passive component capabilities, including germanium photodetectors and silicon nitride waveguides. The <2 month cycle time is competitive. **Primary risk:** Singapore-based; geopolitical exposure similar to GF/AMF.

#### Candidate B: Tower Semiconductor (PH18M)

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>High-volume silicon photonics foundry</td></tr>
  <tr><td>Process</td><td>PH18M (0.18µm SiPho)</td></tr>
  <tr><td>Platform Features</td><td>O-band and C-band PICs; germanium PIN diodes; on-chip integrated III-V laser options; Ansys, Cadence, Luceda, Mentor, Synopsys PDKs</td></tr>
  <tr><td>MPW Schedule</td><td>Regular MPW runs; PH18M-B6408 tape-in May 12, 2026</td></tr>
  <tr><td>Capacity</td><td>Planning to triple SiPho output by mid-2026</td></tr>
  <tr><td>Key Advantage</td><td>Production-proven platform; integrated laser options; multi-vendor PDK support</td></tr>
</table>

**Assessment:** Tower Semiconductor is the strongest production-scale alternative. The PH18M platform supports integrated III-V lasers, which could simplify your PTA design by eliminating external laser coupling. Capacity expansion (3× output by mid-2026) reduces supply risk. **Primary risk:** Tower is a public company with strong financials, but MPW pricing may be higher than GF/AMF.

#### Candidate C: AIM Photonics

<table>
  <tr><th>Field</th><th>Detail</th></tr>
  <tr><td>Service</td><td>300mm silicon photonics MPW</td></tr>
  <tr><td>Process</td><td>Active, passive, SiN, and low-loss active PIC platforms</td></tr>
  <tr><td>MPW Schedule</td><td>Regular runs; ACT 26-01A design due March 2, 2026; ACT2 26-03A2 design due August 15, 2026</td></tr>
  <tr><td>Key Advantage</td><td>US-based 300mm fab; strong defense/research funding</td></tr>
  <tr><td>Grant Eligibility</td><td>US-focused; Canadian eligibility unclear</td></tr>
</table>

**Assessment:** AIM Photonics is a strong research-oriented alternative, particularly for defense-funded projects. The 300mm platform offers advanced capabilities, but the US focus may limit Canadian grant alignment.

## Section 4: Phased Qualification Roadmap

### Phase 1: Desktop Assessment (Q4 2027, Months 1–2)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Cost</th></tr>
  <tr><td>1.1</td><td>Compile candidate supplier profiles (ChipFoundry, Europractice, MOSIS, CompoundTek, Tower, AIM)</td><td>Foundry Ops</td><td>Supplier comparison matrix</td><td>$0</td></tr>
  <tr><td>1.2</td><td>Review quality certifications (ISO 9001, IATF 16949)</td><td>Quality</td><td>Certification checklist</td><td>$0</td></tr>
  <tr><td>1.3</td><td>Assess financial stability (public filings, funding history)</td><td>CFO</td><td>Financial risk memo</td><td>$0</td></tr>
  <tr><td>1.4</td><td>Evaluate grant eligibility (FABrIC, IRAP, NSERC)</td><td>Grant Admin</td><td>Grant eligibility matrix</td><td>$0</td></tr>
  <tr><td>1.5</td><td>Assess IP protection frameworks (NDAs, design watermarking)</td><td>Legal</td><td>IP risk assessment</td><td>$0</td></tr>
  <tr><td>1.6</td><td>Score candidates against qualification decision matrix</td><td>Foundry Ops / CFO</td><td>Ranked candidate list</td><td>$0</td></tr>
  <tr><td>1.7</td><td>Decision Gate 1: Select Tier 2 candidates</td><td>CFO / CTO</td><td>Approved candidate list</td><td>—</td></tr>
</table>

**Phase 1 Budget:** $5,000 (internal time)

### Phase 2: Process Feasibility (Q1–Q2 2028, Months 3–8)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Cost</th></tr>
  <tr><td>2.1</td><td>RISC-V64 SoC/GPU: Register for ChipFoundry chipIgnite shuttle (SKY130)</td><td>Design Eng</td><td>Test chip design</td><td>$15,000</td></tr>
  <tr><td>2.2</td><td>RISC-V64 SoC/GPU: Register for Europractice GF180MCU shuttle</td><td>Design Eng</td><td>Test chip design</td><td>$10,000</td></tr>
  <tr><td>2.3</td><td>PTA: Register for CompoundTek MPW shuttle</td><td>Photonics Eng</td><td>Test chip design</td><td>$25,000</td></tr>
  <tr><td>2.4</td><td>PTA: Register for Tower Semiconductor PH18M MPW shuttle</td><td>Photonics Eng</td><td>Test chip design</td><td>$30,000</td></tr>
  <tr><td>2.5</td><td>PTA: Register for AIM Photonics ACT2 MPW shuttle</td><td>Photonics Eng</td><td>Test chip design</td><td>$20,000</td></tr>
  <tr><td>2.6</td><td>Run test chips through selected shuttles</td><td>Foundry Ops</td><td>Fabricated test chips</td><td>—</td></tr>
  <tr><td>2.7</td><td>Evaluate yield, performance, and cost</td><td>Foundry Ops / Design Eng</td><td>Feasibility report</td><td>—</td></tr>
  <tr><td>2.8</td><td>Decision Gate 2: Select Tier 3 candidates</td><td>CFO / CTO</td><td>Approved design port list</td><td>—</td></tr>
</table>

**Phase 2 Budget:** $100,000

### Phase 3: Design Port (Q3 2028 – Q1 2029, Months 9–16)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Cost</th></tr>
  <tr><td>3.1</td><td>RISC-V64 SoC: Port design to selected alternative (ChipFoundry or Europractice)</td><td>Design Eng</td><td>Ported GDS</td><td>$30,000</td></tr>
  <tr><td>3.2</td><td>GPU: Port design to selected alternative</td><td>Design Eng</td><td>Ported GDS</td><td>$40,000</td></tr>
  <tr><td>3.3</td><td>PTA: Port design to selected alternative (CompoundTek, Tower, or AIM)</td><td>Photonics Eng</td><td>Ported GDS</td><td>$50,000</td></tr>
  <tr><td>3.4</td><td>Run DRC and verification on ported designs</td><td>Design Automation</td><td>DRC-clean GDS</td><td>$10,000</td></tr>
  <tr><td>3.5</td><td>Submit ported designs for fabrication</td><td>Foundry Ops</td><td>Fabrication orders</td><td>—</td></tr>
  <tr><td>3.6</td><td>Evaluate ported design yield and performance</td><td>Foundry Ops</td><td>Port qualification report</td><td>—</td></tr>
  <tr><td>3.7</td><td>Decision Gate 3: Approve Tier 4 production qualification</td><td>CFO / CTO / CEO</td><td>Approved production qual plan</td><td>—</td></tr>
</table>

**Phase 3 Budget:** $130,000

### Phase 4: Production Qualification (Q2–Q4 2029, Months 17–24)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Cost</th></tr>
  <tr><td>4.1</td><td>Run production qualification lots (3–6 lots with enhanced inspection)</td><td>Foundry Ops</td><td>Qualification lots</td><td>$50,000</td></tr>
  <tr><td>4.2</td><td>Reliability testing (HTOL, ESD, latch-up)</td><td>Quality</td><td>Reliability report</td><td>$15,000</td></tr>
  <tr><td>4.3</td><td>Monitor yield and quality metrics vs. primary source</td><td>Foundry Ops</td><td>Dual-source comparison</td><td>$0</td></tr>
  <tr><td>4.4</td><td>Update supplier risk register with qualified alternatives</td><td>CFO</td><td>Updated risk matrix</td><td>$0</td></tr>
  <tr><td>4.5</td><td>Decision Gate 4: Approve dual-sourcing production allocation</td><td>Board</td><td>Approved sourcing strategy</td><td>—</td></tr>
</table>

**Phase 4 Budget:** $65,000

### Total Roadmap Budget

<table>
  <tr><th>Phase</th><th>Timeline</th><th>Budget</th></tr>
  <tr><td>Phase 1: Desktop Assessment</td><td>Q4 2027</td><td>$5,000</td></tr>
  <tr><td>Phase 2: Process Feasibility</td><td>Q1–Q2 2028</td><td>$100,000</td></tr>
  <tr><td>Phase 3: Design Port</td><td>Q3 2028–Q1 2029</td><td>$130,000</td></tr>
  <tr><td>Phase 4: Production Qualification</td><td>Q2–Q4 2029</td><td>$65,000</td></tr>
  <tr><td>Total</td><td>18 months</td><td>$300,000</td></tr>
</table>

## Section 5: Budget & Resource Requirements

### 5.1 Detailed Budget Breakdown

<table>
  <tr><th>Category</th><th>Phase 1</th><th>Phase 2</th><th>Phase 3</th><th>Phase 4</th><th>Total</th></tr>
  <tr><td>Foundry/MPW costs</td><td>$0</td><td>$85,000</td><td>$50,000</td><td>$50,000</td><td>$185,000</td></tr>
  <tr><td>Design engineering labor</td><td>$3,000</td><td>$5,000</td><td>$60,000</td><td>$5,000</td><td>$73,000</td></tr>
  <tr><td>Photonics engineering labor</td><td>$2,000</td><td>$5,000</td><td>$20,000</td><td>$5,000</td><td>$32,000</td></tr>
  <tr><td>Quality/reliability testing</td><td>$0</td><td>$5,000</td><td>$0</td><td>$15,000</td><td>$20,000</td></tr>
  <tr><td>Legal/IP</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td></tr>
  <tr><td>Travel (facility audits)</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td><td>$0</td></tr>
  <tr><td>Total</td><td>$5,000</td><td>$100,000</td><td>$130,000</td><td>$75,000</td><td>$310,000</td></tr>
</table>

### 5.2 Resource Allocation

<table>
  <tr><th>Role</th><th>Phase 1 FTE</th><th>Phase 2 FTE</th><th>Phase 3 FTE</th><th>Phase 4 FTE</th></tr>
  <tr><td>Foundry Operations Manager</td><td>0.25</td><td>0.25</td><td>0.15</td><td>0.25</td></tr>
  <tr><td>Design Engineer (RISC-V64/GPU)</td><td>0.10</td><td>0.10</td><td>0.50</td><td>0.10</td></tr>
  <tr><td>Photonics Engineer</td><td>0.10</td><td>0.20</td><td>0.50</td><td>0.10</td></tr>
  <tr><td>Design Automation Engineer</td><td>0.05</td><td>0.05</td><td>0.15</td><td>0.05</td></tr>
  <tr><td>Quality Engineer</td><td>0.05</td><td>0.05</td><td>0.05</td><td>0.20</td></tr>
  <tr><td>CFO / Grant Admin</td><td>0.05</td><td>0.05</td><td>0.05</td><td>0.05</td></tr>
</table>

### 5.3 Funding Sources

<table>
  <tr><th>Source</th><th>Amount</th><th>Notes</th></tr>
  <tr><td>FABrIC (Round 4/5)</td><td>$124,000</td><td>40% reimbursement on eligible costs</td></tr>
  <tr><td>NRC IRAP</td><td>$75,000</td><td>Salary support for design engineers</td></tr>
  <tr><td>Company cash</td><td>$111,000</td><td>Remaining balance</td></tr>
  <tr><td>Total</td><td>$310,000</td><td></td></tr>
</table>

## Section 6: Risk Assessment & Decision Gates

### 6.1 Qualification Risk Register

<table>
  <tr><th>#</th><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Mitigation</th></tr>
  <tr><td>Q-01</td><td>Design port fails due to process incompatibility</td><td>Medium</td><td>High</td><td>Run test chip first; budget 2× porting effort</td></tr>
  <tr><td>Q-02</td><td>Alternative supplier yield below 70%</td><td>Medium</td><td>High</td><td>Qualify multiple alternatives; don&#39;t rely on single source</td></tr>
  <tr><td>Q-03</td><td>Cost per good die exceeds primary source by &gt;30%</td><td>Medium</td><td>Medium</td><td>Negotiate volume pricing; consider multi-run agreement</td></tr>
  <tr><td>Q-04</td><td>Grant funding not secured for qualification</td><td>Low</td><td>Medium</td><td>Self-fund Phase 1–2; seek grant for Phase 3–4</td></tr>
  <tr><td>Q-05</td><td>IP exposure during design port</td><td>Low</td><td>High</td><td>Execute NDAs; use design watermarking; limit GDS access</td></tr>
  <tr><td>Q-06</td><td>Alternative supplier capacity unavailable</td><td>Medium</td><td>Medium</td><td>Book slots 2 quarters in advance; maintain buffer inventory</td></tr>
</table>

### 6.2 Decision Gate Criteria

<table>
  <tr><th>Gate</th><th>Decision</th><th>Criteria</th><th>Owner</th></tr>
  <tr><td>Gate 1</td><td>Proceed to Phase 2?</td><td>≥2 candidates score ≥3.5 on decision matrix</td><td>CFO / CTO</td></tr>
  <tr><td>Gate 2</td><td>Proceed to Phase 3?</td><td>Test chip yield ≥70%; cost per die ≤150% of primary</td><td>CFO / CTO</td></tr>
  <tr><td>Gate 3</td><td>Proceed to Phase 4?</td><td>Ported design DRC-clean; yield ≥75%</td><td>CFO / CTO / CEO</td></tr>
  <tr><td>Gate 4</td><td>Approve dual-sourcing?</td><td>Production qualification yield ≥80%; reliability tests pass</td><td>Board</td></tr>
</table>

## Section 7: Integration with Existing Processes

### 7.1 Link to Supplier Risk Assessment

<table>
  <tr><th>Risk Matrix Item</th><th>Roadmap Mitigation</th></tr>
  <tr><td>W-01: wafer.space financial instability</td><td>Qualify ChipFoundry and Europractice as alternatives</td></tr>
  <tr><td>G-06: Single-source photonics dependency</td><td>Qualify CompoundTek, Tower, or AIM as alternative</td></tr>
</table>

### 7.2 Link to Grant Applications

<table>
  <tr><th>Grant</th><th>Qualification Cost Eligibility</th><th>Timeline</th></tr>
  <tr><td>FABrIC Round 4/5</td><td>Fabrication process development costs eligible</td><td>Q1 2028 application</td></tr>
  <tr><td>NRC IRAP</td><td>Design engineering labor eligible</td><td>Continuous intake</td></tr>
</table>

### 7.3 Link to Rolling Forecast

<table>
  <tr><th>Phase</th><th>Cash Outflow</th><th>Forecast Impact</th></tr>
  <tr><td>Phase 1</td><td>$5,000</td><td>Minimal</td></tr>
  <tr><td>Phase 2</td><td>$100,000</td><td>R&amp;D expense in Q1–Q2 2028</td></tr>
  <tr><td>Phase 3</td><td>$130,000</td><td>R&amp;D expense in Q3 2028–Q1 2029</td></tr>
  <tr><td>Phase 4</td><td>$75,000</td><td>R&amp;D expense in Q2–Q4 2029</td></tr>
</table>

### 7.4 Link to Board Reporting

The roadmap progress should be reported quarterly to the Board as part of the supplier risk section. Key metrics: number of candidates qualified, spend to date, and risk reduction achieved.

## Section 8: Governance & Next Steps

### 8.1 Governance Structure

<table>
  <tr><th>Role</th><th>Responsibility</th></tr>
  <tr><td>Executive Sponsor</td><td>CFO — owns budget and board reporting</td></tr>
  <tr><td>Technical Lead</td><td>CTO — owns technical qualification decisions</td></tr>
  <tr><td>Project Manager</td><td>Foundry Operations Manager — day-to-day coordination</td></tr>
  <tr><td>Quality Lead</td><td>Quality Engineer — oversees reliability testing</td></tr>
  <tr><td>Grant Liaison</td><td>Grant Admin — ensures grant compliance</td></tr>
</table>

### 8.2 Immediate Next Steps (Next 30 Days)

<table>
  <tr><th>#</th><th>Action</th><th>Owner</th><th>Deadline</th></tr>
  <tr><td>1</td><td>Approve Phase 1 budget ($5,000)</td><td>CFO</td><td>Week 1</td></tr>
  <tr><td>2</td><td>Compile candidate supplier profiles</td><td>Foundry Ops</td><td>Week 2</td></tr>
  <tr><td>3</td><td>Schedule introductory calls with ChipFoundry, Europractice, CompoundTek, Tower</td><td>Foundry Ops</td><td>Week 3</td></tr>
  <tr><td>4</td><td>Request PDK access and NDA templates from top candidates</td><td>Legal</td><td>Week 4</td></tr>
  <tr><td>5</td><td>Present Phase 1 findings to CFO/CTO</td><td>Foundry Ops</td><td>Week 4</td></tr>
</table>

### 8.3 Quarterly Review Cadence

<table>
  <tr><th>Quarter</th><th>Milestone</th><th>Decision Gate</th></tr>
  <tr><td>Q4 2027</td><td>Phase 1 complete</td><td>Gate 1: Select Tier 2 candidates</td></tr>
  <tr><td>Q1 2028</td><td>Test chips submitted</td><td>—</td></tr>
  <tr><td>Q2 2028</td><td>Test chip results available</td><td>Gate 2: Select Tier 3 candidates</td></tr>
  <tr><td>Q3 2028</td><td>Design port initiated</td><td>—</td></tr>
  <tr><td>Q4 2028</td><td>Design port complete</td><td>—</td></tr>
  <tr><td>Q1 2029</td><td>Ported designs fabricated</td><td>Gate 3: Approve production qual</td></tr>
  <tr><td>Q2 2029</td><td>Production qual lots run</td><td>—</td></tr>
  <tr><td>Q4 2029</td><td>Dual-sourcing approved</td><td>Gate 4: Board approval</td></tr>
</table>

---

This multi-source qualification roadmap gives you a structured, staged approach to reducing supplier concentration risk across your RISC-V64 SoC, GPU, and PTA photonics programs. The critical insight is that **Phase 2 (Process Feasibility) is the highest-value investment** — $100,000 in test chip runs will validate whether alternative suppliers can match your yield and cost requirements before you commit to full design ports. The roadmap is designed to be **grant-compatible**, with $199,000 of the $310,000 total potentially eligible for FABrIC or IRAP reimbursement.

---

# Supplier Onboarding Checklist: Fabless Semiconductor Foundry Partners

**Entity:** Gridworkz Fabless AI Chip Company (Canada)  
**Checklist Owner:** Foundry Operations Manager  
**Scope:** New foundry, MPW aggregator, or photonics partner onboarding  
**Applicable Partners:** [wafer.space](https://wafer.space/), GF/AMF, ChipFoundry, Europractice, CompoundTek, Tower Semiconductor

---

## Onboarding Philosophy

Supplier onboarding for a fabless semiconductor company is fundamentally different from onboarding a generic vendor. A foundry partner becomes an extension of your design and production process — they hold your GDS files, control your yield, and determine your unit economics. The onboarding process must therefore cover **legal, technical, commercial, and operational** dimensions, with clearly defined stage gates that prevent you from committing significant NRE spend before foundational agreements are in place.

The process below follows the standard foundry engagement path identified by industry practitioners: mutual NDA → design brief → PDK access → design rule compliance → tape-out → wafer fabrication → packaged silicon. The full cycle takes **8–20 months for prototypes** and **12–24 months for production qualification**.

---

## Phase 1: Pre-Onboarding & Initial Contact (Weeks 1–4)

### 1.1 Supplier Identification & Qualification

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>1.1.1</td><td>Confirm supplier offers the required process node (GF180MCU, SKY130, or silicon photonics)</td><td>Foundry Ops</td><td>Process confirmation</td><td>☐</td></tr>
  <tr><td>1.1.2</td><td>Verify supplier&#39;s ISO certifications (ISO 9001, ISO 14001; IATF 16949 for automotive)</td><td>Quality</td><td>Certificate copies</td><td>☐</td></tr>
  <tr><td>1.1.3</td><td>Review supplier&#39;s financial stability (public filings, funding history, parent company)</td><td>CFO</td><td>Financial risk memo</td><td>☐</td></tr>
  <tr><td>1.1.4</td><td>Confirm supplier&#39;s MPW shuttle schedule and slot availability</td><td>Foundry Ops</td><td>Shuttle calendar</td><td>☐</td></tr>
  <tr><td>1.1.5</td><td>Assess supplier&#39;s grant eligibility (FABrIC, NRC IRAP, NSERC)</td><td>Grant Admin</td><td>Grant eligibility note</td><td>☐</td></tr>
  <tr><td>1.1.6</td><td>Identify supplier&#39;s key contacts (sales, technical support, DRC, finance)</td><td>Foundry Ops</td><td>Contact list</td><td>☐</td></tr>
  <tr><td>1.1.7</td><td>Stage Gate 1: Approve supplier for formal engagement</td><td>CFO / CTO</td><td>Approval memo</td><td>☐</td></tr>
</table>

### 1.2 Mutual NDA Execution

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>1.2.1</td><td>Request supplier&#39;s standard NDA template</td><td>Legal</td><td>NDA template</td><td>☐</td></tr>
  <tr><td>1.2.2</td><td>Review NDA for IP protection adequacy (GDS ownership, design confidentiality, reverse engineering prohibition)</td><td>Legal</td><td>Redline comments</td><td>☐</td></tr>
  <tr><td>1.2.3</td><td>Negotiate mutual NDA terms (duration, permitted disclosures, residual clauses)</td><td>Legal</td><td>Executed NDA</td><td>☐</td></tr>
  <tr><td>1.2.4</td><td>Execute mutual NDA</td><td>CFO / Legal</td><td>Signed NDA</td><td>☐</td></tr>
  <tr><td>1.2.5</td><td>File NDA in compliance folder</td><td>Legal</td><td>Filed copy</td><td>☐</td></tr>
</table>

**Critical Note:** For MPW shuttles, the NDA must explicitly address the multi-project wafer environment. Your GDS files will share a reticle with other participants' designs. The NDA must prohibit the foundry from disclosing your design to other shuttle participants and must establish clear IP ownership of your design.

### 1.3 Design Brief Preparation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>1.3.1</td><td>Prepare high-level design brief (target process, estimated die area, chip type)</td><td>CTO</td><td>Design brief</td><td>☐</td></tr>
  <tr><td>1.3.2</td><td>Prepare statement of work (SOW) defining deliverables, milestones, and acceptance criteria</td><td>Foundry Ops</td><td>SOW</td><td>☐</td></tr>
  <tr><td>1.3.3</td><td>Estimate volume requirements (number of shuttles, die quantity, packaging needs)</td><td>Supply Chain</td><td>Volume forecast</td><td>☐</td></tr>
  <tr><td>1.3.4</td><td>Prepare budget estimate (NRE, slot cost, packaging, test)</td><td>CFO</td><td>Budget memo</td><td>☐</td></tr>
</table>

**Design Brief Contents (for MPW shuttles):** Target process node (e.g., GF180MCU), estimated die area (e.g., 3.88mm × 5.07mm for RISC-V64 SoC), number of slots required, expected die count, packaging requirements (bare die vs. chip-on-board), and target delivery quarter.

---

## Phase 2: Legal & Compliance Onboarding (Weeks 3–6)

### 2.1 Contract Execution

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>2.1.1</td><td>Request supplier&#39;s master services agreement (MSA) or terms and conditions</td><td>Legal</td><td>MSA draft</td><td>☐</td></tr>
  <tr><td>2.1.2</td><td>Review commercial terms (pricing, payment schedule, cancellation policy, liability caps)</td><td>Legal / CFO</td><td>Redline comments</td><td>☐</td></tr>
  <tr><td>2.1.3</td><td>Review IP terms (GDS ownership, mask ownership, background IP, foreground IP)</td><td>Legal</td><td>IP review memo</td><td>☐</td></tr>
  <tr><td>2.1.4</td><td>Review data protection terms (design file handling, security, destruction upon termination)</td><td>Legal</td><td>Data protection review</td><td>☐</td></tr>
  <tr><td>2.1.5</td><td>Negotiate and execute MSA or purchase order terms</td><td>CFO / Legal</td><td>Executed MSA</td><td>☐</td></tr>
  <tr><td>2.1.6</td><td>File executed contract in compliance folder</td><td>Legal</td><td>Filed copy</td><td>☐</td></tr>
</table>

### 2.2 Compliance Documentation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>2.2.1</td><td>Complete supplier&#39;s onboarding registration (ERP supplier portal)</td><td>AP Clerk</td><td>Supplier record created</td><td>☐</td></tr>
  <tr><td>2.2.2</td><td>Acknowledge supplier&#39;s Code of Conduct (e.g., GF Supplier Code of Conduct)</td><td>CFO</td><td>Signed acknowledgement</td><td>☐</td></tr>
  <tr><td>2.2.3</td><td>Complete conflict minerals disclosure (3TG due diligence)</td><td>Supply Chain</td><td>Disclosure form</td><td>☐</td></tr>
  <tr><td>2.2.4</td><td>Complete anti-bribery and anti-corruption certification</td><td>Legal</td><td>Certification</td><td>☐</td></tr>
  <tr><td>2.2.5</td><td>Complete export control and trade compliance review</td><td>Legal</td><td>Compliance memo</td><td>☐</td></tr>
  <tr><td>2.2.6</td><td>Register chemical substances per REACH or applicable regulations (if applicable)</td><td>Quality</td><td>Registration confirmation</td><td>☐</td></tr>
</table>

**GF-Specific Note:** GlobalFoundries requires all suppliers to acknowledge the **GF Supplier Code of Conduct** as part of the onboarding process and when participating in a sourcing event. GF also requires a **Disaster Recovery Plan** from suppliers, describing measures taken to ensure continued supply. Suppliers performing work on GF property must register chemical substances in accordance with REACH legislation.

### 2.3 Financial Onboarding

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>2.3.1</td><td>Set up supplier in ERP system (vendor master record)</td><td>AP Clerk</td><td>Vendor record</td><td>☐</td></tr>
  <tr><td>2.3.2</td><td>Confirm payment terms (net 30, net 60, milestone-based)</td><td>CFO</td><td>Payment terms memo</td><td>☐</td></tr>
  <tr><td>2.3.3</td><td>Confirm banking details and wire instructions</td><td>Treasury</td><td>Banking confirmation</td><td>☐</td></tr>
  <tr><td>2.3.4</td><td>Confirm currency of invoicing (USD, CAD, SGD)</td><td>Treasury</td><td>Currency confirmation</td><td>☐</td></tr>
  <tr><td>2.3.5</td><td>Set up tax withholding and reporting requirements (if cross-border)</td><td>Treasury</td><td>Tax setup</td><td>☐</td></tr>
  <tr><td>2.3.6</td><td>Confirm invoicing requirements (PO number, project code, documentation)</td><td>AP Clerk</td><td>Invoicing guidelines</td><td>☐</td></tr>
</table>

---

## Phase 3: Technical Onboarding (Weeks 4–10)

### 3.1 PDK Access & Setup

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>3.1.1</td><td>Request PDK access (GF180MCU, SKY130, or photonics PDK)</td><td>Design Eng</td><td>PDK request submitted</td><td>☐</td></tr>
  <tr><td>3.1.2</td><td>Execute PDK license agreement (if required)</td><td>Legal</td><td>Signed PDK license</td><td>☐</td></tr>
  <tr><td>3.1.3</td><td>Download and install PDK in design environment</td><td>Design Automation</td><td>PDK installed</td><td>☐</td></tr>
  <tr><td>3.1.4</td><td>Verify PDK version compatibility with EDA tools</td><td>Design Automation</td><td>Compatibility report</td><td>☐</td></tr>
  <tr><td>3.1.5</td><td>Run PDK validation test (simple inverter or ring oscillator)</td><td>Design Eng</td><td>Validation report</td><td>☐</td></tr>
  <tr><td>3.1.6</td><td>Document any PDK issues or gaps</td><td>Design Eng</td><td>PDK issue log</td><td>☐</td></tr>
</table>

**Photonics-Specific Note:** For GF/AMF or CompoundTek photonics PDKs, verify that the PDK includes photonic-specific elements (waveguides, grating couplers, photodetectors, modulators). CompoundTek's PDK version 3.0 was developed in partnership with Siemens Digital Industries Software and Ansys-Lumerical.

### 3.2 Design Rule Compliance Setup

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>3.2.1</td><td>Obtain latest DRC rule deck from supplier</td><td>Design Automation</td><td>DRC rule deck</td><td>☐</td></tr>
  <tr><td>3.2.2</td><td>Obtain antenna rules, density rules, and latch-up rules</td><td>Design Automation</td><td>Complete rule set</td><td>☐</td></tr>
  <tr><td>3.2.3</td><td>Integrate DRC rules into design verification flow</td><td>Design Automation</td><td>DRC flow configured</td><td>☐</td></tr>
  <tr><td>3.2.4</td><td>Run DRC on a test design to validate rule deck</td><td>Design Eng</td><td>DRC clean test</td><td>☐</td></tr>
  <tr><td>3.2.5</td><td>Obtain DRC waiver process documentation</td><td>Design Automation</td><td>Waiver process doc</td><td>☐</td></tr>
  <tr><td>3.2.6</td><td>Confirm maximum DRC iterations allowed (GF/AMF: 3 iterations)</td><td>Foundry Ops</td><td>Iteration limit confirmed</td><td>☐</td></tr>
</table>

**Critical Note:** For GF/AMF photonics shuttles, the GDS submission deadline is the **15th of the month preceding the shuttle run**, and any DRC violation must be **waived by the submission deadline**. A maximum of **3 DRC iterations** is permitted. Each additional iteration incurs approximately **$3,500 in additional cost**.

### 3.3 Test Chip / Feasibility Run

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>3.3.1</td><td>Design a simple test chip (process validation vehicle)</td><td>Design Eng</td><td>Test chip GDS</td><td>☐</td></tr>
  <tr><td>3.3.2</td><td>Submit test chip for fabrication (or include in first MPW shuttle)</td><td>Foundry Ops</td><td>Submission confirmation</td><td>☐</td></tr>
  <tr><td>3.3.3</td><td>Receive and test fabricated test chips</td><td>Design Eng</td><td>Test results</td><td>☐</td></tr>
  <tr><td>3.3.4</td><td>Evaluate yield, performance, and process compatibility</td><td>Foundry Ops</td><td>Feasibility report</td><td>☐</td></tr>
  <tr><td>3.3.5</td><td>Stage Gate 2: Approve supplier for full design submission</td><td>CTO / CFO</td><td>Approval memo</td><td>☐</td></tr>
</table>

**Feasibility Metrics:** Test chip yield ≥70%, process parameters within specification, DRC clean on first or second iteration, and cost per good die within 150% of primary source.

### 3.4 Design Porting (If Required)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>3.4.1</td><td>Assess design portability from current process to supplier&#39;s process</td><td>Design Eng</td><td>Portability assessment</td><td>☐</td></tr>
  <tr><td>3.4.2</td><td>Port design elements (standard cells, I/O, memory) to new PDK</td><td>Design Eng</td><td>Ported design</td><td>☐</td></tr>
  <tr><td>3.4.3</td><td>Re-run synthesis, place-and-route, and timing closure</td><td>Design Eng</td><td>Timing-clean design</td><td>☐</td></tr>
  <tr><td>3.4.4</td><td>Run DRC and LVS on ported design</td><td>Design Automation</td><td>DRC/LVS clean</td><td>☐</td></tr>
  <tr><td>3.4.5</td><td>Document porting effort and lessons learned</td><td>Design Eng</td><td>Porting report</td><td>☐</td></tr>
</table>

---

## Phase 4: Commercial & Operational Onboarding (Weeks 6–12)

### 4.1 Slot/Order Configuration

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>4.1.1</td><td>Confirm slot size and die area allocation</td><td>Foundry Ops</td><td>Slot configuration</td><td>☐</td></tr>
  <tr><td>4.1.2</td><td>Confirm quantity of die per slot</td><td>Foundry Ops</td><td>Die quantity confirmed</td><td>☐</td></tr>
  <tr><td>4.1.3</td><td>Confirm packaging options (bare die, QFN, chip-on-board)</td><td>Supply Chain</td><td>Packaging selection</td><td>☐</td></tr>
  <tr><td>4.1.4</td><td>Confirm shipping and logistics requirements</td><td>Supply Chain</td><td>Logistics plan</td><td>☐</td></tr>
  <tr><td>4.1.5</td><td>Confirm delivery address and customs requirements</td><td>Supply Chain</td><td>Delivery instructions</td><td>☐</td></tr>
</table>

**ChipFoundry chipIgnite Example:** The base price of **$14,950 USD** includes fabrication of one design, **100 QFN packaged parts**, an evaluation board, and test firmware. A **$500 non-refundable reservation deposit** secures the slot. A **50% commitment payment** is due 60 days before the final design submission deadline, and the remaining balance is due **14 days before** the deadline. A **minimum of 20 confirmed participants** is required for the shuttle to proceed.

### 4.2 Payment Schedule Setup

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>4.2.1</td><td>Confirm payment milestones (deposit, commitment, final)</td><td>CFO</td><td>Payment schedule</td><td>☐</td></tr>
  <tr><td>4.2.2</td><td>Set up prepaid asset account for slot deposit</td><td>Controller</td><td>Prepaid Foundry Costs account</td><td>☐</td></tr>
  <tr><td>4.2.3</td><td>Set up WIP account for fabrication costs</td><td>Controller</td><td>WIP – Foundry account</td><td>☐</td></tr>
  <tr><td>4.2.4</td><td>Configure ERP for automatic cost allocation</td><td>Controller</td><td>ERP configuration</td><td>☐</td></tr>
  <tr><td>4.2.5</td><td>Document revenue recognition and grant eligibility treatment</td><td>Controller</td><td>Accounting memo</td><td>☐</td></tr>
</table>

### 4.3 Schedule & Milestone Confirmation

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>4.3.1</td><td>Confirm slot purchase deadline</td><td>Foundry Ops</td><td>Deadline confirmed</td><td>☐</td></tr>
  <tr><td>4.3.2</td><td>Confirm design submission deadline (GDS due date)</td><td>Foundry Ops</td><td>Deadline confirmed</td><td>☐</td></tr>
  <tr><td>4.3.3</td><td>Confirm DRC waiver deadline</td><td>Design Automation</td><td>Deadline confirmed</td><td>☐</td></tr>
  <tr><td>4.3.4</td><td>Confirm expected chip delivery date</td><td>Supply Chain</td><td>Delivery date confirmed</td><td>☐</td></tr>
  <tr><td>4.3.5</td><td>Add all deadlines to project calendar</td><td>Program Mgmt</td><td>Calendar updated</td><td>☐</td></tr>
  <tr><td>4.3.6</td><td>Set internal design freeze milestone (4 weeks before submission)</td><td>Program Mgmt</td><td>Internal deadline set</td><td>☐</td></tr>
</table>

### 4.4 Quality & Reliability Requirements

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>4.4.1</td><td>Confirm incoming inspection requirements for die/chips</td><td>Quality</td><td>Inspection plan</td><td>☐</td></tr>
  <tr><td>4.4.2</td><td>Confirm certificate of conformance (C of C) requirements</td><td>Quality</td><td>C of C template</td><td>☐</td></tr>
  <tr><td>4.4.3</td><td>Confirm reliability testing requirements (HTOL, ESD, latch-up)</td><td>Quality</td><td>Reliability plan</td><td>☐</td></tr>
  <tr><td>4.4.4</td><td>Confirm failure analysis process and turnaround time</td><td>Quality</td><td>FA process doc</td><td>☐</td></tr>
  <tr><td>4.4.5</td><td>Set up quality monitoring metrics (yield, defect density, lot reject rate)</td><td>Quality</td><td>Quality dashboard</td><td>☐</td></tr>
</table>

**Tower Semiconductor Quality Standards:** Tower is certified to **IATF 16949:2016** for the manufacture of integrated microelectronic devices on silicon wafers (excluding product design, per Clause 8.3). Tower's supplier audits assess **14 categories**, including Quality Systems, Design and Change Control, Supplier and Materials Management, Product Control and Traceability, and Training.

---

## Phase 5: Operational Integration (Weeks 8–14)

### 5.1 Communication & Escalation Setup

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>5.1.1</td><td>Establish primary and secondary contacts for technical issues</td><td>Foundry Ops</td><td>Contact matrix</td><td>☐</td></tr>
  <tr><td>5.1.2</td><td>Establish escalation path for critical issues</td><td>Foundry Ops</td><td>Escalation matrix</td><td>☐</td></tr>
  <tr><td>5.1.3</td><td>Set up regular check-in cadence (weekly during active shuttle)</td><td>Program Mgmt</td><td>Meeting invite</td><td>☐</td></tr>
  <tr><td>5.1.4</td><td>Set up DRC query process and expected response time</td><td>Design Automation</td><td>DRC query workflow</td><td>☐</td></tr>
  <tr><td>5.1.5</td><td>Establish shipping notification and tracking process</td><td>Supply Chain</td><td>Logistics workflow</td><td>☐</td></tr>
</table>

### 5.2 ERP & Systems Integration

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>5.2.1</td><td>Configure ERP supplier record with payment terms and currency</td><td>AP Clerk</td><td>ERP supplier setup</td><td>☐</td></tr>
  <tr><td>5.2.2</td><td>Configure WIP tracking for foundry orders</td><td>Controller</td><td>WIP tracking setup</td><td>☐</td></tr>
  <tr><td>5.2.3</td><td>Configure inventory receipt process for die/chips</td><td>Supply Chain</td><td>Receiving workflow</td><td>☐</td></tr>
  <tr><td>5.2.4</td><td>Configure grant expenditure tracking codes</td><td>Grant Admin</td><td>Grant coding setup</td><td>☐</td></tr>
  <tr><td>5.2.5</td><td>Test end-to-end transaction flow (PO → receipt → invoice → payment)</td><td>Controller</td><td>Test transaction</td><td>☐</td></tr>
</table>

### 5.3 Grant & Compliance Integration

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>5.3.1</td><td>Confirm supplier&#39;s documentation meets grant audit requirements</td><td>Grant Admin</td><td>Grant documentation checklist</td><td>☐</td></tr>
  <tr><td>5.3.2</td><td>Set up grant expenditure tracking for supplier invoices</td><td>Grant Admin</td><td>Grant tracking sheet</td><td>☐</td></tr>
  <tr><td>5.3.3</td><td>Confirm supplier&#39;s invoices include grant-required information (project number, description)</td><td>AP Clerk</td><td>Invoice template</td><td>☐</td></tr>
  <tr><td>5.3.4</td><td>Add supplier to grant compliance calendar (reporting deadlines)</td><td>Grant Admin</td><td>Calendar updated</td><td>☐</td></tr>
</table>

---

## Phase 6: First Shuttle Execution & Post-Onboarding Review (Weeks 12–24)

### 6.1 First Shuttle Execution

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>6.1.1</td><td>Submit design GDS by deadline</td><td>Design Eng</td><td>Submission confirmation</td><td>☐</td></tr>
  <tr><td>6.1.2</td><td>Monitor DRC iterations and resolve issues</td><td>Design Automation</td><td>DRC clean confirmation</td><td>☐</td></tr>
  <tr><td>6.1.3</td><td>Confirm tape-out and fabrication start</td><td>Foundry Ops</td><td>Tape-out confirmation</td><td>☐</td></tr>
  <tr><td>6.1.4</td><td>Track fabrication progress and WIP</td><td>Foundry Ops</td><td>WIP tracking</td><td>☐</td></tr>
  <tr><td>6.1.5</td><td>Receive and inspect die/chips upon delivery</td><td>Quality</td><td>Receiving report</td><td>☐</td></tr>
  <tr><td>6.1.6</td><td>Test die/chips and evaluate yield</td><td>Design Eng</td><td>Test report</td><td>☐</td></tr>
</table>

### 6.2 Post-Onboarding Review (60 Days After First Delivery)

<table>
  <tr><th>#</th><th>Task</th><th>Owner</th><th>Deliverable</th><th>Done</th></tr>
  <tr><td>6.2.1</td><td>Conduct formal post-onboarding review meeting</td><td>Foundry Ops</td><td>Meeting minutes</td><td>☐</td></tr>
  <tr><td>6.2.2</td><td>Evaluate supplier performance against KPIs (yield, OTD, DRC)</td><td>Foundry Ops</td><td>Performance scorecard</td><td>☐</td></tr>
  <tr><td>6.2.3</td><td>Document lessons learned and process improvements</td><td>Program Mgmt</td><td>Lessons learned doc</td><td>☐</td></tr>
  <tr><td>6.2.4</td><td>Update supplier risk assessment with actual performance data</td><td>CFO</td><td>Updated risk matrix</td><td>☐</td></tr>
  <tr><td>6.2.5</td><td>Confirm supplier is added to Approved Vendor List (AVL)</td><td>Quality</td><td>AVL updated</td><td>☐</td></tr>
  <tr><td>6.2.6</td><td>Stage Gate 3: Approve supplier for ongoing engagement</td><td>CFO / CTO</td><td>Approval memo</td><td>☐</td></tr>
</table>

---

## Partner-Specific Onboarding Notes

### [wafer.space](https://wafer.space/) (GF180MCU MPW)

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>GF180MCU (180nm)</td></tr>
  <tr><td>Slot Purchase</td><td>Via CrowdSupply campaign page; early-bird pricing available</td></tr>
  <tr><td>Chip Delivery</td><td>wafer.space handles dicing and shipping</td></tr>
  <tr><td>PDK</td><td>GF180MCU open-source PDK</td></tr>
  <tr><td>Submission Platform</td><td>wafer.space portal</td></tr>
  <tr><td>Key Risk</td><td>Early-stage venture; qualify alternative MPW aggregator</td></tr>
</table>

### GF/AMF (Silicon Photonics)

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>AMF silicon photonics platform</td></tr>
  <tr><td>PDK Access</td><td>Technology agreement and PDK access required</td></tr>
  <tr><td>GDS Deadline</td><td>15th of the month preceding the shuttle run</td></tr>
  <tr><td>DRC Limit</td><td>Max 3 DRC iterations</td></tr>
  <tr><td>DRC Waiver</td><td>Must be waived by submission deadline</td></tr>
  <tr><td>Key Risk</td><td>Yield gap (72% vs. 85% standard); AMF integration risk</td></tr>
</table>

### ChipFoundry (chipIgnite / SKY130)

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>SKY130 (130nm)</td></tr>
  <tr><td>Reservation</td><td>$500 non-refundable deposit</td></tr>
  <tr><td>Commitment</td><td>50% of project cost due 60 days before submission</td></tr>
  <tr><td>Final Payment</td><td>Remaining balance due 14 days before submission</td></tr>
  <tr><td>Base Price</td><td>$14,950 USD (includes 100 QFN parts + eval board)</td></tr>
  <tr><td>Minimum</td><td>20 confirmed participants required</td></tr>
  <tr><td>Key Risk</td><td>Process migration from GF180MCU to SKY130</td></tr>
</table>

### Europractice

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>Multiple (GF 180nm MCU available via Fraunhofer IIS)</td></tr>
  <tr><td>Access</td><td>Through Europractice IC Service</td></tr>
  <tr><td>Pricing</td><td>Discounted (academic) and Standard pricing</td></tr>
  <tr><td>Key Advantage</td><td>Direct GF180MCU access without process porting</td></tr>
  <tr><td>Key Risk</td><td>Canadian eligibility for discounted pricing uncertain</td></tr>
</table>

### CompoundTek (Silicon Photonics)

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>8&quot; silicon photonics; 130nm and 180nm Si CMOS</td></tr>
  <tr><td>Capabilities</td><td>Suspended edge couplers, 90nm Si nano waveguide, 150nm SiN nano waveguide, V-grooves</td></tr>
  <tr><td>MPW Schedule</td><td>Regular shuttles; ~2 months turnaround</td></tr>
  <tr><td>PDK</td><td>Version 3.0 (with Lumerical and other PDA/EDA vendors)</td></tr>
  <tr><td>Key Advantage</td><td>Dedicated photonics fab; fast porting from other foundries</td></tr>
  <tr><td>Key Risk</td><td>Singapore-based; not Canadian grant-eligible</td></tr>
</table>

### Tower Semiconductor (PH18M)

<table>
  <tr><th>Aspect</th><th>Requirement</th></tr>
  <tr><td>Process</td><td>PH18M (0.18µm SiPho)</td></tr>
  <tr><td>Capabilities</td><td>O-band and C-band PICs; germanium PIN diodes; integrated III-V laser options</td></tr>
  <tr><td>PDK</td><td>Ansys, Cadence, Luceda, Mentor, Synopsys</td></tr>
  <tr><td>Quality</td><td>IATF 16949:2016 certified</td></tr>
  <tr><td>Key Advantage</td><td>Production-proven platform; capacity expansion (3× by mid-2026)</td></tr>
  <tr><td>Key Risk</td><td>Higher MPW pricing than GF/AMF</td></tr>
</table>

---

## Onboarding Checklist Summary by Role

<table>
  <tr><th>Role</th><th>Key Onboarding Responsibilities</th></tr>
  <tr><td>Foundry Operations Manager</td><td>Supplier identification, shuttle scheduling, slot configuration, logistics, performance review</td></tr>
  <tr><td>CTO</td><td>Design brief, technical feasibility assessment, stage gate approvals</td></tr>
  <tr><td>CFO</td><td>Financial risk assessment, NDA/contract review, budget approval, payment schedule setup</td></tr>
  <tr><td>Legal</td><td>NDA execution, MSA negotiation, IP protection review, export control compliance</td></tr>
  <tr><td>Design Engineer</td><td>PDK installation, test chip design, design porting, DRC resolution</td></tr>
  <tr><td>Design Automation Engineer</td><td>DRC rule integration, PDK validation, EDA flow setup</td></tr>
  <tr><td>Supply Chain</td><td>Packaging selection, shipping logistics, inventory receipt, conflict minerals disclosure</td></tr>
  <tr><td>Quality Engineer</td><td>ISO certification review, incoming inspection plan, reliability testing setup</td></tr>
  <tr><td>Grant Administrator</td><td>Grant eligibility assessment, documentation compliance, expenditure tracking setup</td></tr>
  <tr><td>AP Clerk</td><td>Supplier registration, invoice processing, payment execution</td></tr>
  <tr><td>Controller</td><td>Prepaid asset setup, WIP tracking, grant coding, ERP configuration</td></tr>
</table>

---

## Onboarding Timeline Summary

<table>
  <tr><th>Phase</th><th>Duration</th><th>Key Milestone</th><th>Stage Gate</th></tr>
  <tr><td>Phase 1: Pre-Onboarding</td><td>Weeks 1–4</td><td>NDA executed; design brief prepared</td><td>Gate 1: Approve for formal engagement</td></tr>
  <tr><td>Phase 2: Legal &amp; Compliance</td><td>Weeks 3–6</td><td>MSA executed; compliance documentation complete</td><td>—</td></tr>
  <tr><td>Phase 3: Technical Onboarding</td><td>Weeks 4–10</td><td>PDK access; DRC setup; test chip fabricated</td><td>Gate 2: Approve for full design submission</td></tr>
  <tr><td>Phase 4: Commercial &amp; Operational</td><td>Weeks 6–12</td><td>Slot confirmed; payment schedule set; quality plan in place</td><td>—</td></tr>
  <tr><td>Phase 5: Operational Integration</td><td>Weeks 8–14</td><td>ERP setup; communication channels established</td><td>—</td></tr>
  <tr><td>Phase 6: First Shuttle &amp; Review</td><td>Weeks 12–24</td><td>First chips received and tested</td><td>Gate 3: Approve for ongoing engagement</td></tr>
</table>

**Total Onboarding Duration:** 12–24 weeks (3–6 months) from initial contact to first chip delivery.

---

This supplier onboarding checklist gives you a complete, role-based framework for bringing a new foundry partner online — from initial NDA through first silicon delivery. The critical insight is that **Phase 3 (Technical Onboarding) is the highest-risk phase**: PDK gaps, DRC rule mismatches, and test chip yield failures discovered here prevent costly full-design submissions to an incompatible process. The stage gates are designed to ensure you never commit significant NRE spend without validated technical compatibility.

---

# E1-E5 Items Overview

Here are concrete examples for each of the five items in your chip fab report. Each example draws from documented industry standards and tooling that you can adapt directly into our report.

---

## 1. Acceptance Model and Representative Dataset — Version, Source, and Hash

### Example: MLPerf Inference v5.0 — ResNet50-v1.5

<table>
  <tr><th>Field</th><th>Entry</th></tr>
  <tr><td>Acceptance Model</td><td>ResNet50-v1.5</td></tr>
  <tr><td>Model Version</td><td>MLPerf reference implementation, v1.5 (frozen)</td></tr>
  <tr><td>Model Source</td><td>MLCommons inference repository (github.com/mlcommons/inference)</td></tr>
  <tr><td>Model Hash (SHA-256)</td><td>Published in the MLPerf inference rules; computed over the frozen ONNX/TF checkpoint</td></tr>
  <tr><td>Representative Dataset</td><td>ImageNet-2012 (224×224) Validation</td></tr>
  <tr><td>Dataset Size</td><td>50,000 samples</td></tr>
  <tr><td>QSL Size</td><td>1,024 samples</td></tr>
  <tr><td>Reference Accuracy</td><td>76.46% Top-1</td></tr>
  <tr><td>Server Latency Constraint</td><td>15 ms</td></tr>
  <tr><td>Number of Parameters</td><td>25.6 million</td></tr>
  <tr><td>FLOPs</td><td>3.8 billion</td></tr>
</table>

The MLPerf Inference Rules specify that the deterministic random number generator is the **Mersenne Twister 19937** (`std::mt19937`), and random seeds are announced four weeks before the submission deadline. The rules also mandate that benchmark implementations must be shared under an open-source license and that results that cannot be replicated are not valid.

**For your fab report:** Record the exact model checkpoint hash (SHA-256), the dataset manifest hash (content hash of the full dataset), and the QSL (Query Sample Library) hash. The dataset hash should be built by hashing every sample and folding the ordered list of sample digests into one final digest, with order being part of the identity.

---

## 2. Input Preparation — Preprocessing, Layouts, Quantization, Supported Operators/Shapes

### 2.1 Preprocessing Pipeline Example

<table>
  <tr><th>Stage</th><th>Operation</th><th>Parameters</th><th>Output Shape</th></tr>
  <tr><td>Resize</td><td>Bilinear interpolation to 256×256</td><td>interpolation=bilinear</td><td>(256, 256, 3)</td></tr>
  <tr><td>CenterCrop</td><td>Crop to 224×224</td><td>crop_size=224</td><td>(224, 224, 3)</td></tr>
  <tr><td>Mean subtraction</td><td>Subtract ImageNet mean</td><td>mean=[0.485, 0.456, 0.406]</td><td>(224, 224, 3)</td></tr>
  <tr><td>Std normalization</td><td>Divide by ImageNet std</td><td>std=[0.229, 0.224, 0.225]</td><td>(224, 224, 3)</td></tr>
  <tr><td>Layout transform</td><td>HWC → CHW → NCHW</td><td>—</td><td>(1, 3, 224, 224)</td></tr>
  <tr><td>Quantization</td><td>Linear affine, per-tensor</td><td>scale=0.0078125, zero_point=128</td><td>(1, 3, 224, 224) int8</td></tr>
</table>

Preprocessing parameters such as mean and std are configurable per channel, with the mean specified as `[val1, val2, val3]` and normalization standard deviation applied similarly.

### 2.2 Quantization Specification (ONNX QONNX / QuantizeLinear)

The linear quantization operator follows the formula:

**y = saturate((x / y_scale) + y_zero_point)**

<table>
  <tr><th>Attribute</th><th>Options / Semantics</th></tr>
  <tr><td>Signed</td><td>Boolean: true → signed interval, false → unsigned</td></tr>
  <tr><td>Narrow</td><td>Boolean: true → narrow by 1 (e.g., [-127, 127] instead of [-128, 127])</td></tr>
  <tr><td>Rounding mode</td><td>ROUND (round-to-even), ROUND_TO_ZERO, CEIL, FLOOR</td></tr>
  <tr><td>Bit width</td><td>Integer ≥ 2</td></tr>
  <tr><td>Granularity</td><td>Per-tensor (scalar scale), per-axis (1-D tensor), or blocked (scale shape matches input except blocking dimension)</td></tr>
</table>

**Saturation ranges by data type:**

<table>
  <tr><th>Type</th><th>Saturation Range</th></tr>
  <tr><td>uint8</td><td>[0, 255]</td></tr>
  <tr><td>int8</td><td>[-128, 127]</td></tr>
  <tr><td>uint4</td><td>[0, 15]</td></tr>
  <tr><td>int4</td><td>[-8, 7]</td></tr>
  <tr><td>uint2</td><td>[0, 3]</td></tr>
  <tr><td>int2</td><td>[-2, 1]</td></tr>
</table>

Saturation is applied according to the target data type, and for `(x / y_scale)`, the operation **rounds to the nearest even**.

### 2.3 Supported Operators and Shapes (ONNX / CoreML Example)

<table>
  <tr><th>Operator</th><th>Shape Constraint</th><th>Note</th></tr>
  <tr><td>ai.onnx:Conv</td><td>1D/2D only</td><td>Weights and bias must be constant</td></tr>
  <tr><td>ai.onnx:AveragePool</td><td>2D Pool only</td><td>—</td></tr>
  <tr><td>ai.onnx:GlobalAveragePool</td><td>2D Pool only</td><td>—</td></tr>
  <tr><td>ai.onnx:PRelu</td><td>Input slope constant</td><td>Shape [C, 1, 1] or 1 element</td></tr>
  <tr><td>ai.onnx:Pad</td><td>Constant mode</td><td>Last two dim padding only; pads and constant_value constant</td></tr>
  <tr><td>ai.onnx:MatMul</td><td>Input B constant</td><td>—</td></tr>
  <tr><td>ai.onnx:Gemm</td><td>Input B constant</td><td>—</td></tr>
</table>

This operator list is representative of the constraints documented in ONNX Runtime's CoreML supported operators specification.

---

## 3. Numerical Behavior — Reference Semantics, Rounding, Saturation, Golden Vectors

### 3.1 Reference Semantics

For fixed-point arithmetic, two overflow behaviors are defined:

<table>
  <tr><th>Mode</th><th>Semantics</th><th>Preferred When</th></tr>
  <tr><td>Saturation</td><td>Result clamped to nearest representable value</td><td>Hardware naturally operates on fixed-point types; prevents wraparound artifacts</td></tr>
  <tr><td>Wrap-around</td><td>Modular arithmetic; result wraps to opposite end</td><td>Rarely preferred; used in specific DSP contexts</td></tr>
</table>

The overflow mode can be interpreted as `omode = {sat, wrap}`, where `sat` represents saturation and `wrap` represents wrap-around. In the absence of an explicit saturating fixed-point type, overflow behavior is controlled by pragmas such as **FX_FRACT_OVERFLOW** and **FX_ACCUM_OVERFLOW** with **SAT** and **DEFAULT** as possible states.

### 3.2 Rounding Modes

<table>
  <tr><th>Rounding Mode</th><th>Description</th></tr>
  <tr><td>ROUND</td><td>Round-to-nearest, ties to even (default for ONNX QuantizeLinear)</td></tr>
  <tr><td>ROUND_TO_ZERO</td><td>Truncation toward zero</td></tr>
  <tr><td>CEIL</td><td>Round toward positive infinity</td></tr>
  <tr><td>FLOOR</td><td>Round toward negative infinity</td></tr>
</table>

The QONNX specification confirms that "rounding modes can be configured" and that `ROUND` implies a round-to-even operation.

### 3.3 Golden Vector Generation

**Deterministic seed-driven approach:** Golden vectors are defined as **deterministic seeds + distribution descriptors + tolerance + baseline statement**. The contract is: any harness that consumes the vector file, seeds the named PRNG with `seed_u32`, samples N vectors from `distribution`, and runs them through both paths, **MUST report identical statistics down to the documented tolerance**. This keeps the vector file small (constant size, independent of N) while remaining bit-reproducible for any conformant implementation.

**Example vector pack structure:**

<table>
  <tr><th>Field</th><th>Value</th></tr>
  <tr><td>vector_set_id</td><td>gf16_vs_bfloat16_v0</td></tr>
  <tr><td>seed_u32</td><td>1234567890</td></tr>
  <tr><td>distribution</td><td>normal(0, 1)</td></tr>
  <tr><td>sample_count</td><td>16</td></tr>
  <tr><td>vector_length</td><td>8</td></tr>
  <tr><td>tolerance</td><td>1e-6</td></tr>
  <tr><td>baseline</td><td>bfloat16 round-trip reference</td></tr>
</table>

**Golden vector hash certification:** Each golden vector artifact should be accompanied by a SHA-256 hash. For example, a certified artifact table might list `Golden_Watch_Chiral_Null_Analysis` with SHA-256 `99da2133c64f3510189c67cbed5f...`.

**For your fab report:** The golden vector pack should be **hashed and versioned** alongside the design manifest, with an enforcement check that a future manifest committed without a reproducible design fails the test suite outright.

---

## 4. Success Thresholds and Measurement Boundaries

### 4.1 Quality Thresholds (MLPerf Examples)

<table>
  <tr><th>Benchmark</th><th>Quality Metric</th><th>Target</th><th>Tolerance</th></tr>
  <tr><td>ResNet50-v1.5</td><td>Top-1 Accuracy</td><td>76.46%</td><td>Datacenter: ≥99% of reference; Edge: ≥99%</td></tr>
  <tr><td>Stable Diffusion</td><td>CLIP Score</td><td>31.74981837</td><td>Within 0.2% of reference</td></tr>
  <tr><td>Stable Diffusion</td><td>FID Score</td><td>23.48046692</td><td>Within 2% of reference</td></tr>
  <tr><td>Retinanet</td><td>mAP</td><td>0.3755</td><td>High-accuracy variant available</td></tr>
  <tr><td>3d-unet</td><td>Mean DICE</td><td>0.86330</td><td>High-accuracy variant available</td></tr>
</table>

### 4.2 Latency Thresholds and Measurement Boundaries

<table>
  <tr><th>Benchmark</th><th>Scenario</th><th>Latency Constraint</th><th>Measurement Boundary</th></tr>
  <tr><td>ResNet50-v1.5</td><td>Server</td><td>15 ms</td><td>99th-percentile latency estimate</td></tr>
  <tr><td>Retinanet</td><td>Server</td><td>100 ms</td><td>99th-percentile latency</td></tr>
  <tr><td>MLPerf Tiny</td><td>SingleStream</td><td>—</td><td>90th-percentile latency estimate</td></tr>
</table>

**Measurement boundary definition:** A measurement contract requires the **same model, input set, batch/reuse conditions, output-quality target, latency definition, and energy boundary**. Warm-up, calibration, model writes, fallback, I/O, and stabilization need an explicit amortization policy. MLPerf distinguishes model-quality and system-performance conditions and uses **whole-system power boundaries** for power results.

### 4.3 Power and Energy Measurement

<table>
  <tr><th>Metric</th><th>Requirement</th><th>Sampling Rate</th><th>Accuracy</th></tr>
  <tr><td>Power</td><td>Intervals ≤ 10% of core phase duration</td><td>≥ 1 Hz, constant</td><td>Internal device sampling ≥ 1 Hz</td></tr>
  <tr><td>Energy</td><td>Per-inference energy</td><td>External micro-power instruments for microcontroller workloads</td><td>±3% from 25% to 100% of max load</td></tr>
  <tr><td>Energy (TinyML)</td><td>Energy per inference</td><td>Integrated measurement</td><td>Baseline + 10% tolerance</td></tr>
</table>

### 4.4 Named Owners and Reviewers

For your fab report, each threshold should have a named owner and reviewer:

<table>
  <tr><th>Threshold Category</th><th>Owner</th><th>Reviewer</th><th>Acceptance Authority</th></tr>
  <tr><td>Model quality (accuracy/FID/CLIP)</td><td>AI/ML Lead</td><td>CTO</td><td>CTO</td></tr>
  <tr><td>Latency (p90/p99)</td><td>Design Engineer</td><td>Foundry Ops Manager</td><td>CTO</td></tr>
  <tr><td>Power (whole-system boundary)</td><td>Hardware Lead</td><td>Quality Engineer</td><td>CFO / CTO</td></tr>
  <tr><td>Energy per inference</td><td>Photonics/Systems Engineer</td><td>Quality Engineer</td><td>CTO</td></tr>
  <tr><td>Golden vector reproducibility</td><td>Design Automation Engineer</td><td>Verification Lead</td><td>CTO</td></tr>
</table>

---

## 5. Versioned Spec and Data Manifest — Regenerable Reference Outputs

### 5.1 Versioned Spec and Manifest Structure (SiliconCompiler Example)

SiliconCompiler provides a documented example of a versioned spec and data manifest system. For every compilation run, it **automatically records**:

<table>
  <tr><th>Recorded Item</th><th>Description</th></tr>
  <tr><td>SiliconCompiler Version</td><td>Exact framework version (e.g., v0.35.1)</td></tr>
  <tr><td>Tool Details</td><td>Version of each tool executed (Yosys, OpenROAD) and command-line options</td></tr>
  <tr><td>Timestamps</td><td>Start and end times for each task</td></tr>
  <tr><td>User (optional)</td><td>Username of person who initiated the run</td></tr>
  <tr><td>Machine (optional)</td><td>Hostname where the run was executed</td></tr>
</table>

These records are captured for each individual task (defined by step and index) in the flowgraph, ensuring every action is documented.

**Manifest file format:** SiliconCompiler writes a manifest file (`sc_manifest.tcl`) in the work directory containing a nested TCL dictionary called `sc_cfg` with the entire project configuration. For tools driven by TCL scripts, the script sources this manifest and reads from the `sc_cfg` dictionary.

**Schema versioning:** Manifests use `.pkg.json` format, and the schema version (`schemaversion`) is recorded in every manifest with its own changelog, which is the authoritative record of what was added, renamed, or removed at each version.

### 5.2 Data Manifest with Content Hashing

A data manifest records:

<table>
  <tr><th>Field</th><th>Example</th></tr>
  <tr><td>dataset_hash</td><td>SHA-256 of all sample digests folded in order</td></tr>
  <tr><td>per_sample_hash</td><td>SHA-256 of each individual sample</td></tr>
  <tr><td>parent_links</td><td>Reference to the dataset version the model trained on</td></tr>
  <tr><td>num_samples</td><td>100</td></tr>
  <tr><td>metadata.split</td><td>&quot;train&quot;</td></tr>
  <tr><td>prml.version</td><td>&quot;prml/0.1&quot; (manifest schema version)</td></tr>
  <tr><td>prml.metric</td><td>&quot;accuracy&quot; (pre-registered metric)</td></tr>
</table>

The dataset hash is built by hashing every sample and then folding the ordered list of sample digests into one final digest. **Order is part of the identity**: the same samples in a different order are a different version, which matches how a training split is actually consumed.

**Hash-based version control:** A piece of data is identified by the hash of what it contains, not by a filename or modified time. If two datasets contain the same samples in the same order, they get the same hash. If even a single pixel changes, the hash changes and the change is detected.

### 5.3 Reference Output Regeneration Verification

<table>
  <tr><th>Verification Step</th><th>Method</th><th>Expected Result</th></tr>
  <tr><td>Hash recomputation</td><td>Recompute SHA-256 of every artifact</td><td>Matches manifest hash</td></tr>
  <tr><td>Drift detection</td><td>verify() recomputes artifact hashes and flags drift</td><td>Preflight refuses to publish if hashes don&#39;t match</td></tr>
  <tr><td>Golden vector replay</td><td>Seed PRNG with seed_u32, sample from distribution, run through both paths</td><td>Identical statistics down to tolerance</td></tr>
  <tr><td>Provenance chain walk</td><td>Follow parents mapping from model manifest to dataset manifest</td><td>Unbroken chain of custody from source to final artifact</td></tr>
  <tr><td>Schema validation</td><td>Validate manifest against schemaversion changelog</td><td>No missing, renamed, or removed fields</td></tr>
</table>

**Example verification contract:** A model manifest stores the dataset hash it trained on, which lets you walk a chain of artifacts back to the raw data they came from. The manifest carries a `parents` mapping, and the dataset hash is stored in the model manifest as `dataset_hash`.

**For your fab report:** Confirm that the reference outputs can be regenerated by (1) recomputing all hashes from source artifacts, (2) replaying golden vectors with the documented seeds and tolerance, and (3) walking the provenance chain from final layout back to source code without breaks.

---

## Summary Table: What to Record for Each Item

<table>
  <tr><th>Report Item</th><th>What to Record</th><th>Example Format</th></tr>
  <tr><td>1. Acceptance model &amp; dataset</td><td>Model version, model SHA-256, dataset version, dataset SHA-256, QSL hash, reference accuracy</td><td>ResNet50-v1.5 / SHA-256 a1b2c3... / ImageNet-2012 / SHA-256 d4e5f6...</td></tr>
  <tr><td>2. Input preparation</td><td>Preprocessing ops, mean/std, layout, quantization scheme, rounding mode, bit width, supported operator list</td><td>Bilinear 256 → CenterCrop 224 → Mean/Std → NCHW → int8 per-tensor ROUND</td></tr>
  <tr><td>3. Numerical behavior</td><td>Overflow mode (sat/wrap), rounding mode, golden vector seed + distribution + tolerance, vector pack hash</td><td>SAT, ROUND_TO_EVEN, seed=1234567890, normal(0,1), tol=1e-6, SHA-256 ...</td></tr>
  <tr><td>4. Success thresholds</td><td>Quality target, latency constraint, power boundary, energy per inference, named owner, named reviewer</td><td>Top-1 ≥ 76.46%, p99 ≤ 15ms, whole-system power, owner=AI Lead, reviewer=CTO</td></tr>
  <tr><td>5. Spec &amp; manifest</td><td>Versioned spec, manifest schema version, dataset hash, per-sample hashes, parent links, regeneration evidence</td><td>schemaversion 0.35.1, dataset_hash SHA-256, parents.trained_on, hash recomputation log</td></tr>
</table>
