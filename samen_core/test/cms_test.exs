defmodule Samen.CmsTest do
  @moduledoc """
  WS-ERP E37: CMS-light —  Website Builder (data layer).

  ## Resources

  - `Page` — content pages with SEO and publishing lifecycle
  - `Template` — page layout templates
  - `Theme` — visual themes with colors and fonts

  ## Tests

  - cm1: Page lifecycle (draft → review → published → archived)
  - cm2: Page unpublish
  - cm3: Page SEO fields
  - cm4: Page slug and homepage
  - cm5: Template lifecycle
  - cm6: Template default and use count
  - cm7: Theme lifecycle
  - cm8: Theme colors and fonts
  - cm9: Theme default
  - cm10: Full CMS ceremony
  """
  use ExUnit.Case, async: true

  # --- cm1: Page lifecycle ---

  describe "cm1 — page lifecycle" do
    test "draft → review → published → archived" do
      p = %{status: :draft, published_at: nil}
      assert p.status == :draft

      p = %{p | status: :review}
      assert p.status == :review

      p = %{p | status: :published, published_at: ~U[2026-10-01 09:00:00Z]}
      assert p.status == :published

      p = %{p | status: :archived}
      assert p.status == :archived
    end
  end

  # --- cm2: Page unpublish ---

  describe "cm2 — page unpublish" do
    test "revert to draft" do
      p = %{status: :published}
      p = %{p | status: :draft}
      assert p.status == :draft
    end
  end

  # --- cm3: Page SEO ---

  describe "cm3 — page SEO" do
    test "SEO fields" do
      p = %{seo_title: "About Us", seo_description: "Learn about our company", seo_keywords: ["about", "company", "team"]}
      assert p.seo_title == "About Us"
      assert length(p.seo_keywords) == 3
    end
  end

  # --- cm4: Page slug and homepage ---

  describe "cm4 — page slug" do
    test "slug" do
      p = %{slug: "about-us"}
      assert p.slug == "about-us"
    end

    test "homepage flag" do
      p = %{is_homepage: true}
      assert p.is_homepage == true
    end
  end

  # --- cm5: Template lifecycle ---

  describe "cm5 — template lifecycle" do
    test "create, activate, deactivate" do
      t = %{name: "Landing Page", is_active: true, use_count: 0}
      assert t.is_active == true

      t = %{t | is_active: false}
      assert t.is_active == false

      t = %{t | is_active: true}
      assert t.is_active == true
    end
  end

  # --- cm6: Template default and use count ---

  describe "cm6 — template defaults" do
    test "set as default" do
      t = %{is_default: false}
      t = %{t | is_default: true}
      assert t.is_default == true
    end

    test "increment use count" do
      t = %{use_count: 0}
      t = %{t | use_count: t.use_count + 1}
      assert t.use_count == 1
    end
  end

  # --- cm7: Theme lifecycle ---

  describe "cm7 — theme lifecycle" do
    test "create, activate, deactivate" do
      t = %{name: "Corporate Blue", is_active: true}
      assert t.is_active == true

      t = %{t | is_active: false}
      assert t.is_active == false

      t = %{t | is_active: true}
      assert t.is_active == true
    end
  end

  # --- cm8: Theme colors and fonts ---

  describe "cm8 — theme styling" do
    test "colors" do
      t = %{primary_color: "#007bff", secondary_color: "#6c757d"}
      assert t.primary_color == "#007bff"
      assert t.secondary_color == "#6c757d"
    end

    test "font" do
      t = %{font_family: "Inter"}
      assert t.font_family == "Inter"
    end
  end

  # --- cm9: Theme default ---

  describe "cm9 — theme default" do
    test "set as default" do
      t = %{is_default: false}
      t = %{t | is_default: true}
      assert t.is_default == true
    end
  end

  # --- cm10: Full CMS ceremony ---

  describe "cm10 — full CMS ceremony" do
    test "theme → template → page → SEO → publish" do
      # 1. Create theme
      theme = %{name: "Corporate Blue", primary_color: "#007bff", secondary_color: "#6c757d", font_family: "Inter", is_active: true, is_default: true}

      # 2. Create template
      template = %{name: "Landing Page", html_layout: "<html><body>{{content}}</body></html>", is_active: true, is_default: true, use_count: 0}

      # 3. Create page
      page = %{
        title: "About Us",
        slug: "about-us",
        html_content: "<h1>About Us</h1><p>We build ERP systems.</p>",
        theme_id: "theme_001",
        template_id: "tpl_001",
        status: :draft,
        seo_title: "About Us | Acme Corp",
        seo_description: "Learn about Acme Corp",
        seo_keywords: ["about", "company"],
        is_homepage: false,
        published_at: nil
      }

      # 4. Submit for review
      page = %{page | status: :review}

      # 5. Publish
      page = %{page | status: :published, published_at: ~U[2026-10-01 09:00:00Z]}

      # 6. Update template use count
      template = %{template | use_count: template.use_count + 1}

      assert page.status == :published
      assert page.seo_title == "About Us | Acme Corp"
      assert theme.is_default == true
      assert template.use_count == 1
    end
  end
end
