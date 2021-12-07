defmodule Codebattle.Game.Context do
  @moduledoc """
  The Game context.
  Public interface to interacting with games.
  """

  import Ecto.Query
  import Codebattle.Game.Auth

  alias Codebattle.CodeCheck.CheckResult
  alias Codebattle.CodeCheck.CheckResultV2
  alias Codebattle.Game
  alias Codebattle.Repo
  alias Codebattle.User
  alias Codebattle.Tournament

  alias Codebattle.Game.{
    Server,
    Engine,
    Helpers,
    LiveGames
  }

  @type raw_game_id :: String.t() | non_neg_integer
  @type game_id :: non_neg_integer
  @type tournament_id :: non_neg_integer

  @type game_params :: %{
          task: Codebattle.Task.t() | nil,
          state: String.t() | nil,
          level: String.t() | nil,
          type: String.t() | nil,
          visibility_type: String.t() | nil,
          tournament_id: tournament_id | nil,
          timeout_seconds: non_neg_integer | nil,
          players: nonempty_list(User.t()) | nonempty_list(Tournament.Types.Player.t())
        }

  def get_live_games(params \\ %{}), do: LiveGames.get_games(params)

  @spec get_completed_games() :: [Game.t()]
  def get_completed_games do
    query =
      from(
        games in Game,
        order_by: [desc_nulls_last: games.finishes_at],
        where: [state: "game_over"],
        limit: 30,
        preload: [:users, :user_games]
      )

    Repo.all(query)
  end

  @spec get_game(raw_game_id) :: Game.t() | no_return
  def get_game(id) when is_binary(id) do
    id |> String.to_integer() |> get_game
  end

  def get_game(id) do
    case Server.get_game(id) do
      {:ok, game} -> mark_as_live(game)
      {:error, :not_found} -> get_from_db!(id)
    end
  end

  @spec create_game(game_params) :: {:ok, Game.t()} | {:error, atom}
  def create_game(game_params) do
    case Engine.create_game(game_params) do
      {:ok, game} -> {:ok, mark_as_live(game)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec join_game(game_id, User.t()) :: {:ok, Game.t()} | {:error, atom}
  def join_game(id, user) do
    Engine.join_game(get_game(id), user)
  end

  @spec cancel_game(game_id, User.t()) :: :ok | {:error, atom}
  def cancel_game(id, user) do
    Engine.cancel_game(get_game(id), user)
  end

  @spec update_editor_data(game_id, User.t(), String.t(), String.t()) ::
          {:ok, Game.t()} | {:error, atom}
  def update_editor_data(id, user, editor_text, editor_lang) do
    game = get_game(id)

    case Engine.update_editor_data(game, %{
           id: user.id,
           editor_text: editor_text,
           editor_lang: editor_lang
         }) do
      {:ok, game} -> {:ok, game}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec check_result(game_id, %{
          user: User.t(),
          editor_text: String.t(),
          editor_lang: String.t()
        }) ::
          {
            :ok,
            Game.t(),
            %{check_result: CheckResult.t() | CheckResultV2.t(), solution_status: boolean}
          }
          | {:error, atom}
  def check_result(id, params) do
    id |> get_game() |> Engine.check_result(params)
  end

  @spec give_up(game_id, User.t()) :: {:ok, Game.t()} | {:error, atom}
  def give_up(id, user) do
    id |> get_game() |> Engine.give_up(user)
  end

  @spec rematch_send_offer(raw_game_id, User.t()) ::
          {:ok, {:rematch_status_updated, Game.t()}}
          | {:ok, {:rematch_accepted, Game.t()}}
          | {:error, atom}
  def rematch_send_offer(game_id, user) do
    with game <- get_game(game_id),
         :ok <- player_can_rematch?(game, user.id) do
      Engine.rematch_send_offer(game, user)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rematch_reject(game_id) :: {:ok, Game.t()} | {:error, atom}
  def rematch_reject(game_id) do
    case Server.call_transition(game_id, :rematch_reject, %{}) do
      {:ok, {_old_game, new_game}} ->
        {:rematch_update_status,
         %{
           rematch_initiator_id: new_game.rematch_initiator_id,
           rematch_state: new_game.rematch_state
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec trigger_timeout(game_id) :: :ok
  def trigger_timeout(game_id) do
    Engine.trigger_timeout(get_game(game_id))
    :ok
  end

  @spec terminate_game(game_id | Game.t()) :: :ok
  def terminate_game(%Game{} = game) do
    Engine.terminate_game(game)
  end

  def terminate_game(id), do: get_game(id) |> terminate_game()

  defp set_random_level(params) do
    level = Enum.random(["elementary", "easy", "medium", "hard"])
    Map.put(params, :level, level)
  end

  defp get_from_db!(id) do
    query = from(g in Game, where: g.id == ^id, preload: [:task, :users, :user_games])
    Repo.one!(query)
  end

  defp mark_as_live(game), do: Map.put(game, :is_live, true)
end
