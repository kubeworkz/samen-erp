defmodule Samenerp.Release do
  @moduledoc """
  Release module for database migrations and seeding.

  This module provides functions for running migrations and seeding the database
  in production releases. It's used by the Dockerfile and deployment scripts.

  ## Usage

      # Run migrations
      Samenerp.Release.migrate()

      # Seed the database
      Samenerp.Release.seed()

      # Rollback migrations
      Samenerp.Release.rollback()
  """

  @app :samenerp

  @doc """
  Run all pending migrations.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rollback the last migration.
  """
  def rollback do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, step: 1))
    end
  end

  @doc """
  Seed the database with initial data.
  """
  def seed do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _repo ->
        seed_file = Application.app_dir(@app, "priv/repo/seeds.exs")

        if File.exists?(seed_file) do
          Code.eval_file(seed_file)
        else
          IO.puts("No seed file found at #{seed_file}")
        end
      end)
    end
  end

  @doc """
  Run migrations for a specific repo.
  """
  def migrate_repo(repo) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end

  @doc """
  Rollback migrations for a specific repo.
  """
  def rollback_repo(repo) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, step: 1))
  end

  @doc """
  Check migration status for all repos.
  """
  def migration_status do
    load_app()

    for repo <- repos() do
      IO.puts("\n#{inspect(repo)}:")
      Ecto.Migrator.with_repo(repo, fn repo ->
        status = Ecto.Migrator.migrations(repo)
        Enum.each(status, fn {version, name, status} ->
          IO.puts("  #{version} #{name} (#{status})")
        end)
      end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
