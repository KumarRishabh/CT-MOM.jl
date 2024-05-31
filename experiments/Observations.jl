using PrettyTables
using Revise
using Plots
using Random
using ProgressMeter
# using JLD2 # for saving and loading the data efficiently
include("../src/ContactProcess.jl")
using .ContactProcess
using JLD2
using Distributions
Random.seed!(10)
using Parameters
using Distributed
using Serialization
using FileIO

dir_path = joinpath(@__DIR__)
@with_kw mutable struct Particle
    # state of the particle is defined as a 2D array with the same dimensions as the grid
    state::Array{Bool, 2} = zeros(Bool, 12, 12) # 20 x 20 grid with all zeros
    weight::Float64 = 1.0
    # age::Int = 0 # age of the particle
    # child::Int = 0 # 0 means the particle has no parent
    # id::Int = 0 # parent of the particle

end

grid_params = ContactProcess.GridParameters(width = 10, height = 10)
model_params = ContactProcess.ModelParameters(infection_rate = 0.05, recovery_rate = 0.1, time_limit = 10, prob_infections = 0.05, num_simulations = 1000) # rates are defined to be per day
state, rates = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode = "fixed_probability")

# Select a node in the M \times M grid at random 
# with rate = 100 and observe the state of the node with some error 
# For example, if X[i, j] = 1 (infected) then the observtion is correct with probability 0.80
# and if X[i, j] = 0 (not infected) then the observation is correct with probability 0.95
counter::Int = 0 
function initialize_particles_as_vectors(num_particles, grid_params, model_params)
    particles = Vector{Particle}()
    for i ∈ 1:num_particles
        initial_state, initial_rate = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode="fixed_probability")
        push!(particles, Particle(state = initial_state, weight = 1.0))
    end
    return particles
end
function biased_initialize_particles_as_vectors(num_particles, grid_params, model_params)
    particles = Vector{Particle}()
    for i ∈ 1:3
        initial_state, initial_rate = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode="fixed_probability")
        push!(particles, Particle(state = initial_state, weight = 1.0))
    end
    for i ∈ 4:num_particles
        initial_state, initial_rate = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode="fixed_probability")
        push!(particles, Particle(state=initial_state, weight=10.0))
    end
    return particles
end


function initialize_particles_as_hashmap(num_particles, grid_params, model_params)::Dict{Int,Vector{Particle}}
    particles = Dict{Int,Vector{Particle}}()
    for i ∈ 1:num_particles
        initial_state, initial_rate = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode="complete_chaos")
        particles[i] = [Particle(state = initial_state, weight = 1.0)]
    end
    return particles
end

function initialize_particles_with_signals_as_hashmap(num_particles, grid_params, model_params, signal_state, signal_rate)::Dict{Int,Vector{Particle}}
    particles = Dict{Int,Vector{Particle}}()
    for i ∈ 1:Int(num_particles)
        initial_state, initial_rate = ContactProcess.initialize_state_and_rates(grid_params, model_params, mode="fixed_probability")
        particles[i] = [Particle(state = initial_state, weight = 1.0)]
    end
    return particles
end

function observe_node(state, i, j; infection_error_rate = 0.80, recovery_error_rate = 0.95)
    if state[i, j] == true
        return rand() < infection_error_rate
    else
        return rand() > recovery_error_rate
    end
end

function observe_state(state; infection_error_rate = 0.80, recovery_error_rate = 0.95, rate = 100)
    
    # select a node at random and observe the state of the node
    i, j = rand(2:(size(state, 1) - 1)), rand(2:(size(state, 2)-1))
    time = rand(Exponential(1/rate)) 
    observed_state = (observe_node(state, i, j, infection_error_rate = infection_error_rate, recovery_error_rate = recovery_error_rate), (i ,j))

    return observed_state, time
end



function get_observations_from_state_sequence(state_sequence, time_limit, transition_times; infection_error_rate = 0.80, recovery_error_rate = 0.95, rate = 100)
    observations = []
    times = []
    current_time = 0.0
    while current_time < time_limit
        if current_time == 0.0
            observed_state, time = observe_state(state_sequence[1], infection_error_rate=infection_error_rate, recovery_error_rate=recovery_error_rate, rate=rate)
        else    
            observed_state, time = observe_state(state_sequence[findlast(x -> x <= current_time, transition_times)], infection_error_rate=infection_error_rate, recovery_error_rate=recovery_error_rate, rate=rate)
        end
        push!(observations, observed_state)
        push!(times, time + current_time)
        current_time = times[end]
    end
    return observations, times
end

function get_observations(state, time_limit; infection_error_rate = 0.80, recovery_error_rate = 0.95, rate = 100)
    observations = []
    times = []
    current_time = 0
    while current_time < time_limit
        observed_state, time = observe_state(state, infection_error_rate = infection_error_rate, recovery_error_rate = recovery_error_rate, rate = rate)
        push!(observations, observed_state)
        # if times is empty then push the time otherwise push the time + the last element in times (write a ternary if-else)
        push!(times, isempty(times) ? time : time + times[end])
        current_time = times[end]
    end
    return observations, times
end

function likelihood(hidden_state, observed_state)
    # q_bar is the canonical probability of the observed state given the hidden state which is 1/2
    if hidden_state[observed_state[2][1], observed_state[2][2]] == true
        if observed_state[1] == true
            return 0.8
        else
            return 0.2
        end
    end 

    if observed_state[1] == true
        return 0.05
    else
        return 0.95
    end
    
end

function count_total_particles(particle_history, time_stamp)
    total_particles = 0
    time_stamp = Float32(time_stamp)
    for key in keys(particle_history[Float32(time_stamp)])
        total_particles += length(particle_history[time_stamp][key])
    end
    return total_particles
end

function count_total_particles(particles)
    return length(particles)
end
# Let's initialize states and rates and observe the state
particles
count_total_particles(initialize_particles_as_vectors(100, grid_params, model_params))

# instead of storing the particle_history as a dictionary, write the particle_history to a file
# Also, instead of storing the particle_history as a dictionary, store it as a vector
function branching_particle_filter(initial_num_particles, grid_params, model_params, observation_time_stamps, observations ; r=1.5, signal_state=zeros(Bool, 12, 12), signal_rate=100.0)

    t_curr, t_next = 0, 0
    initial_particles = initialize_particles_as_vectors(initial_num_particles, grid_params, model_params)
    # particle_history = Dict{Float32,Dict{Int,Vector{Particle}}}()
    # Use a vector{vector{Particle}} instead of a dictionary
    particle_history = Vector{Vector{Particle}}()
    # particle_history = Dict{Float32,Vector{Particle}}() # use a vector instead of a dictionary   
    push!(particle_history, deepcopy(initial_particles))
    new_particles = deepcopy(initial_particles)
    average_weights = sum([particle.weight for particle in new_particles]) / initial_num_particles
    progress = Progress(length(observation_time_stamps), 1, "Starting the particle filter...")

    for i ∈ eachindex(observation_time_stamps)
        next!(progress)
        if i != length(observation_time_stamps)
            t_curr = t_next
            t_next = observation_time_stamps[i]
        else
            t_curr = t_next
            t_next = model_params.time_limit
        end

        new_model_params = ContactProcess.ModelParameters(infection_rate=0.05, recovery_rate=0.1, time_limit=t_next, prob_infections=0.05, num_simulations=1000) # rates are defined to be per day
        total_particles = count_total_particles(new_particles)
 

        for j ∈ 1:total_particles
            state = deepcopy(new_particles[j].state)
            rates = ContactProcess.calculate_all_rates(state, grid_params, new_model_params)
            X_sequence, _, _ = ContactProcess.run_simulation!(state, rates, grid_params, new_model_params)
            new_particles[j].state = copy(X_sequence[end])

            if average_weights > exp(20) || average_weights < exp(-20)
                new_particles[j].weight = new_particles[j].weight * likelihood(X_sequence[end], observations[i]) * 2 / average_weights
                # new_particles[j].weight = 2 / average_weights
            else
                new_particles[j].weight = new_particles[j].weight * likelihood(X_sequence[end], observations[i]) * 2
                # new_particles[j].weight = 2
            end
            open("$dir_path/output.txt", "a") do file
                println(file, "Particle weight: ", new_particles[j].weight, " for $j th particle at time $t_curr")
            end
        end

        average_weights = sum([particle.weight for particle in new_particles]) / total_particles
        open("$dir_path/output.txt", "a") do file
            println(file, "Average weights at time $t_curr: ", average_weights)
        end
        temp_particles = deepcopy(new_particles)
        deleted_particles = 0
        total_offsprings = 0
        for j ∈ 1:total_particles
            V = 0.2 * rand() - 0.1
            if ((average_weights / r <= new_particles[j].weight + V) && (new_particles[j].weight + V <= average_weights * r)) == false # To branch
                num_offspring = floor(Int, new_particles[j].weight / average_weights)
                # println("The Bernoulli parameter is:", (new_particles[j].weight / average_weights) - num_offspring)
                num_offspring += rand(Bernoulli((new_particles[j].weight / average_weights) - num_offspring))
                # new_particles[j].weight = deepcopy(average_weights)
                temp_particles[j - deleted_particles].weight = deepcopy(average_weights)
                if num_offspring > 0 # branch the particle
                    # println("Branching particle: ", j, " with ", num_offspring, " offsprings")
                    for _ ∈ 1:(num_offspring-1)
                        push!(temp_particles, deepcopy(new_particles[j]))
                        
                    end
                    total_offsprings += num_offspring - 1

                else # kill the particle
                    # println("Killing particle: ", j)
                    deleteat!(temp_particles, j - deleted_particles)
                    # println("Total Particles: ", count_total_particles(temp_particles))
                    deleted_particles += 1
                end
            end
        end

        new_particles = deepcopy(temp_particles) # update the particles
        open("$dir_path/output.txt", "a") do file
            println(file, "Destroyed particles: ", deleted_particles, " Total offsprings: ", total_offsprings)
            println(file, "Total Particles at the end of the iteration $i: ", count_total_particles(new_particles))
        end
        push!(particle_history, new_particles)

    end
    return particle_history
end


grid_params = ContactProcess.GridParameters(width = 10, height = 10)
model_params = ContactProcess.ModelParameters(infection_rate = 0.025, recovery_rate = 0.05, time_limit = 2, prob_infections = 0.5, num_simulations = 1000) # rates are defined to be per day

state, rates = ContactProcess.initialize_state_and_rates(grid_params, model_params; mode = "fixed_probability")
state_sequence, transition_times, updated_nodes = ContactProcess.run_simulation!(state, rates, grid_params, model_params)
observed_state, time = observe_state(state)
observed_state
observations, observation_time_stamps = get_observations_from_state_sequence(state_sequence, model_params.time_limit, transition_times)
observed_dict = Dict(observation_time_stamps .=> observations)
initial_num_particles = 1000 # initially start with 100 particles
# between the observation time stamps, simulate the contact process with state and rates
V = 0.2*rand() - 0.1
U = 0.2*rand() - 0.1

initialize_particles(initial_num_particles, grid_params, model_params)

particle_history = branching_particle_filter(initial_num_particles, grid_params, model_params, observation_time_stamps, observations, r=5, signal_state=state, signal_rate=rates)

# particle_history = load("$dir_path/particle_history.jls")

# actual_number_of_infections = []
# for i ∈ eachindex(observation_time_stamps)
#     push!(actual_number_of_infections, sum(state_sequence[findlast(x -> x <= observation_time_stamps[i], transition_times)]))
# end

# estimated_number_of_infections = []
# # use particle weights to do a weighted average of the number of infections for each particle
# for i ∈ eachindex(observation_time_stamps)
#     estimate = 0
#     normalization_factor = 0
#     for j ∈ 1:initial_num_particles
#         estimate += sum([particle.weight * sum(particle.state) for particle in particle_history[Float32(observation_time_stamps[i])][j]])
#         normalization_factor += sum([particle.weight for particle in particle_history[Float32(observation_time_stamps[i])][j]])
#     end 
#     estimate /= normalization_factor
#     push!(estimated_number_of_infections, estimate)
# end
# print("Actual number of infections: ", actual_number_of_infections)
# print("Estimated number of infections: ", estimated_number_of_infections)

# println("Initial number of particles: ", initial_num_particles)
# println("Total number of particles: ", count_total_particles(particle_history, observation_time_stamps[end]))
# # plot the actual number of infections and the estimated number of infections
# println("Number of observations: ", length(observation_time_stamps))
# println("Length of actual number of infections: ", length(actual_number_of_infections))
# plot(observation_time_stamps, actual_number_of_infections, label = "Actual number of infections", xlabel = "Time", ylabel = "Number of infections", title = "Actual vs Estimated number of infections")
# plot!(observation_time_stamps, estimated_number_of_infections, label = "Estimated number of infections")


# make a heatmap of the estimated number of infections at each time stamp and compare it with the actual number of infections
# do a weighted average of the infection using particle.weights
function estimate_infection_grid(particle_history, time_stamp)
    estimate = zeros(Float64, 12, 12)
    normalization_factor = 0
    for j ∈ 1:initial_num_particles
        for particle in particle_history[Float32(time_stamp)][j]
            estimate .+= particle.weight * particle.state
            normalization_factor += particle.weight
        end
    end
    estimate /= normalization_factor

    return estimate
end

function actual_infection_grid(state_sequence, time_stamp, transition_times)
    return state_sequence[findlast(x -> x <= time_stamp, transition_times)]
end

function calculate_error(estimate, actual_signal)
    error = 0
    for i in 1:size(estimate, 1)
        for j in 1:size(estimate, 2)
            error += (estimate[i, j] - actual_signal[i, j])^2
        end
    end

    return error/(size(estimate, 1) * size(estimate, 2))
end

function calculate_error_trajectory(particle_history, observation_time_stamps, state_sequence, transition_times)
    errors = []
    for i ∈ eachindex(observation_time_stamps)
        estimate = estimate_infection_grid(particle_history, observation_time_stamps[i])
        actual_signal = actual_infection_grid(state_sequence, observation_time_stamps[i], transition_times)
        error = calculate_error(estimate, actual_signal)
        push!(errors, error)
    end
    return errors
end
length(observation_time_stamps)
errors = calculate_error_trajectory(particle_history, observation_time_stamps, state_sequence, transition_times)
plot(observation_time_stamps, errors, label = "Error", xlabel = "Time", ylabel = "Error", title = "Error in estimating the infection grid")
savefig("error_plot_2.png")
function get_heatmap_data(particle_history, time_stamp)
    heatmap_data = []
    i = Float32(time_stamp)
    estimate = zeros(Float64, 17, 17)
    normalization_factor = 0
    for j ∈ 1:initial_num_particles
        # estimate += sum([particle.weight * particle.state for particle in particle_history[i][j]])
        # do a scalar multiplication of the state with the weight of the particle and then do element-wise addition
        for particle in particle_history[i][j]
            # check if particle.state is a 17 x 17 matrix
            
            estimate .+= particle.weight * particle.state
        end

        normalization_factor += sum([particle.weight for particle in particle_history[i][j]])
    end
    estimate /= normalization_factor
    push!(heatmap_data, estimate)

    return heatmap_data
end

# sample random time_stamps from the observation_time_stamps
function plot_heatmap(heatmap_data, time_stamp)
    P = heatmap(heatmap_data, color = :grays)
    return P
end

sample_time_stamps = sample(observation_time_stamps, 5)

particle_history = load("$dir_path/particle_history.jld")

# save particle history to a csv file
function save_particle_history(particle_history, file_name)
    open(file_name, "w") do io
        for time in keys(particle_history)
            total_particles = count_total_particles(particle_history[time])
            for i ∈ 1:total_particles
                particle = particle_history[time][i]
            
                write(io, "$time, $i, $(particle.state), $(particle.weight)\n")
            
            end
        end
    end
end

save_particle_history(particle_history, "$dir_path/particle_history.csv")
function save_simulation_to_csv(state_sequence, transition_times, file_name)
    open(file_name, "w") do io
        for i ∈ 1:length(transition_times)
            write(io, "$transition_times[i], $(state_sequence[i])\n")
        end
    end
end

save_particle_history(particle_history, "$dir_path/particle_history.csv")

