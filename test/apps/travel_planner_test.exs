defmodule TravelPlannerTest do
  use ExUnit.Case, async: false

  alias TravelPlanner

  @brief %{
    destination: "Kyoto",
    days: 3,
    budget: 1200,
    itineraries: [
      %{id: :economy, cost: 600, days: ~w(d1 d2 d3), activities: 4},
      %{id: :premium, cost: 2000, days: ~w(d1 d2 d3), activities: 9},
      %{id: :long_stay, cost: 900, days: ~w(d1 d2 d3 d4 d5), activities: 6}
    ]
  }

  test "agents/0 defines the three negotiation roles" do
    assert TravelPlanner.agents() == [:budget, :schedule, :experience]
  end

  test "plan/1 negotiates and outputs one agreed itinerary" do
    assert %{id: id, days: days} = TravelPlanner.plan(@brief)
    assert id in [:economy, :premium, :long_stay]
    assert is_list(days) and days != []
  end

  test "plan/1 picks the itinerary with the best combined role scores" do
    # budget and schedule both prefer :economy; experience prefers :premium
    assert %{id: :economy} = TravelPlanner.plan(@brief)
  end

  test "evaluate/2 accepts unanimous votes" do
    votes = [
      %{role: :budget, choice: :economy, score: 0.5},
      %{role: :schedule, choice: :economy, score: 1.0},
      %{role: :experience, choice: :economy, score: 0.5}
    ]

    assert {:ok, :economy} = TravelPlanner.evaluate(votes)
  end

  test "evaluate/2 falls back to score threshold on split votes" do
    votes = [
      %{role: :budget, choice: :economy, score: 0.5},
      %{role: :schedule, choice: :economy, score: 1.0},
      %{role: :experience, choice: :premium, score: 1.0}
    ]

    assert {:ok, :economy} = TravelPlanner.evaluate(votes)
  end

  test "evaluate/2 rejects weak consensus" do
    votes = [
      %{role: :budget, choice: :premium, score: 0.0},
      %{role: :schedule, choice: :long_stay, score: 0.3},
      %{role: :experience, choice: :premium, score: 0.2}
    ]

    # :premium has the most votes but its average score is below threshold
    assert :no_consensus = TravelPlanner.evaluate(votes)
  end

  test "evaluate/2 returns :no_consensus on empty votes" do
    assert :no_consensus = TravelPlanner.evaluate([])
  end
end
