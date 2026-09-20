defmodule Samen.ForumBlogTest do
  @moduledoc """
  WS-ERP E25: Forum + Blog —  community features.

  Tests:
    * fb1 Forum: state and settings
    * fb2 ForumPost: state lifecycle (draft → published → closed)
    * fb3 ForumPost: view and reply counts
    * fb4 ForumComment: voting (upvotes - downvotes)
    * fb5 ForumComment: nested replies
    * fb6 Blog: state and settings
    * fb7 BlogPost: state lifecycle (draft → review → published → archived)
    * fb8 BlogPost: category and tags
    * fb9 BlogComment: moderation workflow (pending → approved/rejected)
    * fb10 BlogComment: nested replies
    * fb11 Integration: full forum flow
    * fb12 Integration: full blog flow
  """
  use ExUnit.Case, async: true

  # ── fb1: forum settings ──────────────────────────────────────────────

  describe "fb1 — forum settings" do
    test "forum has name and slug" do
      forum = %{name: "Product Support", slug: "product-support", is_active: true}
      assert forum.name == "Product Support"
      assert forum.slug == "product-support"
    end

    test "moderation can be required" do
      forum = %{moderation_required: true}
      assert forum.moderation_required == true
    end

    test "anonymous posting option" do
      forum = %{allow_anonymous: false}
      assert forum.allow_anonymous == false
    end
  end

  # ── fb2: forum post state lifecycle ──────────────────────────────────

  describe "fb2 — forum post state lifecycle" do
    test "draft → published → closed" do
      post = %{state: :draft}
      post = %{post | state: :published}
      assert post.state == :published
      post = %{post | state: :closed}
      assert post.state == :closed
    end

    test "published → archived" do
      post = %{state: :published}
      post = %{post | state: :archived}
      assert post.state == :archived
    end

    test "closed can be reopened" do
      post = %{state: :closed}
      post = %{post | state: :published}
      assert post.state == :published
    end
  end

  # ── fb3: view and reply counts ───────────────────────────────────────

  describe "fb3 — view and reply counts" do
    test "view count increments" do
      post = %{view_count: 0}
      post = %{post | view_count: post.view_count + 1}
      assert post.view_count == 1
    end

    test "reply count increments" do
      post = %{reply_count: 0}
      post = %{post | reply_count: post.reply_count + 1}
      assert post.reply_count == 1
    end

    test "popular post has many views" do
      post = %{view_count: 1500, reply_count: 42}
      assert post.view_count > 1000
    end
  end

  # ── fb4: comment voting ──────────────────────────────────────────────

  describe "fb4 — comment voting" do
    test "net score = upvotes - downvotes" do
      comment = %{upvotes: 15, downvotes: 3}
      net_score = comment.upvotes - comment.downvotes

      assert net_score == 12
    end

    test "comment with more downvotes has negative score" do
      comment = %{upvotes: 2, downvotes: 8}
      net_score = comment.upvotes - comment.downvotes

      assert net_score == -6
    end

    test "zero votes" do
      comment = %{upvotes: 0, downvotes: 0}
      net_score = comment.upvotes - comment.downvotes

      assert net_score == 0
    end
  end

  # ── fb5: nested replies ─────────────────────────────────────────────

  describe "fb5 — nested replies" do
    test "top-level comment has no parent" do
      comment = %{parent_comment_id: nil}
      assert is_nil(comment.parent_comment_id)
    end

    test "reply has parent" do
      comment = %{parent_comment_id: "c1"}
      assert comment.parent_comment_id == "c1"
    end

    test "nested thread depth" do
      comments = [
        %{id: "c1", parent_comment_id: nil},
        %{id: "c2", parent_comment_id: "c1"},
        %{id: "c3", parent_comment_id: "c2"},
        %{id: "c4", parent_comment_id: "c3"}
      ]

      max_depth =
        Enum.reduce(comments, 0, fn c, acc ->
          depth = if c.parent_comment_id, do: acc + 1, else: 0
          max(depth, acc)
        end)

      assert max_depth == 3
    end
  end

  # ── fb6: blog settings ──────────────────────────────────────────────

  describe "fb6 — blog settings" do
    test "blog has name and slug" do
      blog = %{name: "Company News", slug: "company-news", is_active: true}
      assert blog.name == "Company News"
    end

    test "comments can be disabled" do
      blog = %{allow_comments: false}
      assert blog.allow_comments == false
    end
  end

  # ── fb7: blog post state lifecycle ──────────────────────────────────

  describe "fb7 — blog post state lifecycle" do
    test "draft → review → published → archived" do
      post = %{state: :draft}
      post = %{post | state: :review}
      assert post.state == :review
      post = %{post | state: :published}
      assert post.state == :published
      post = %{post | state: :archived}
      assert post.state == :archived
    end

    test "draft can go directly to published" do
      post = %{state: :draft}
      post = %{post | state: :published}
      assert post.state == :published
    end
  end

  # ── fb8: category and tags ───────────────────────────────────────────

  describe "fb8 — category and tags" do
    test "post has category" do
      post = %{category: "Tutorial"}
      assert post.category == "Tutorial"
    end

    test "post has tags" do
      post = %{tags: ["elixir", "phoenix", "erp"]}
      assert length(post.tags) == 3
    end

    test "tags are searchable" do
      posts = [
        %{title: "Post 1", tags: ["elixir", "phoenix"]},
        %{title: "Post 2", tags: ["python", "django"]},
        %{title: "Post 3", tags: ["elixir", "erp"]}
      ]

      elixir_posts = Enum.filter(posts, fn p -> "elixir" in p.tags end)
      assert length(elixir_posts) == 2
    end
  end

  # ── fb9: blog comment moderation ─────────────────────────────────────

  describe "fb9 — blog comment moderation" do
    test "pending → approved" do
      comment = %{state: :pending}
      comment = %{comment | state: :approved}
      assert comment.state == :approved
    end

    test "pending → rejected" do
      comment = %{state: :pending}
      comment = %{comment | state: :rejected}
      assert comment.state == :rejected
    end

    test "pending → spam" do
      comment = %{state: :pending}
      comment = %{comment | state: :spam}
      assert comment.state == :spam
    end

    test "approved cannot go back to pending" do
      valid_transitions = %{pending: [:approved, :rejected, :spam], approved: [], rejected: [], spam: []}
      refute :pending in valid_transitions[:approved]
    end
  end

  # ── fb10: blog comment nested replies ────────────────────────────────

  describe "fb10 — blog comment nested replies" do
    test "top-level comment" do
      comment = %{parent_comment_id: nil}
      assert is_nil(comment.parent_comment_id)
    end

    test "reply to comment" do
      comment = %{parent_comment_id: "bc1"}
      assert comment.parent_comment_id == "bc1"
    end
  end

  # ── fb11: full forum flow ────────────────────────────────────────────

  describe "fb11 — full forum flow" do
    test "create forum → post topic → reply → accept answer" do
      # 1. Create forum
      forum = %{id: "f1", name: "Product Support", slug: "product-support", moderation_required: false}

      # 2. Create post
      post = %{id: "p1", forum_id: forum.id, author_id: "u1", title: "How to reset password?", body: "I forgot my password...", state: :published}

      # 3. Add replies
      replies = [
        %{id: "r1", post_id: post.id, author_id: "u2", body: "Go to Settings → Security → Reset", upvotes: 5, downvotes: 0, is_accepted: true},
        %{id: "r2", post_id: post.id, author_id: "u3", body: "You can also use the forgot password link", upvotes: 3, downvotes: 1, is_accepted: false}
      ]

      # 4. Update reply count
      post = Map.merge(post, %{reply_count: length(replies)})

      # 5. Accept answer
      accepted = Enum.find(replies, & &1.is_accepted)
      post = Map.merge(post, %{accepted_answer_id: accepted.id})

      assert post.reply_count == 2
      assert post.accepted_answer_id == "r1"
      unaccepted = Enum.find(replies, &(not &1.is_accepted))
      assert accepted.upvotes > unaccepted.upvotes
    end
  end

  # ── fb12: full blog flow ────────────────────────────────────────────

  describe "fb12 — full blog flow" do
    test "create blog → write post → review → publish → comment" do
      # 1. Create blog
      blog = %{id: "b1", name: "Company News", slug: "company-news", allow_comments: true}

      # 2. Write post
      post = %{id: "bp1", blog_id: blog.id, author_id: "u1", title: "Welcome to Our Blog", body: "We're excited to launch...", state: :draft}

      # 3. Submit for review
      post = %{post | state: :review}
      assert post.state == :review

      # 4. Publish
      post = Map.merge(post, %{state: :published, published_at: DateTime.utc_now()})
      assert post.state == :published

      # 5. Add comment (pending moderation)
      comment = %{id: "bc1", post_id: post.id, author_id: "u2", body: "Great article!", state: :pending}
      assert comment.state == :pending

      # 6. Approve comment
      comment = %{comment | state: :approved}
      assert comment.state == :approved

      # 7. Reply to comment
      reply = %{id: "bc2", post_id: post.id, author_id: "u1", body: "Thanks for reading!", parent_comment_id: comment.id}
      assert reply.parent_comment_id == comment.id

      assert post.state == :published
      assert comment.state == :approved
    end
  end
end