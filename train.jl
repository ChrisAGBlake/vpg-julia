include("./cartpole_env.jl")
using .CartPoleEnv
using Flux, Distributions
using Flux: params, update!
using Statistics: mean
using Plots
using Dates: now

# N.B. this won't work with a batch of states
function act(actor, act_log_std, state)
    σ = exp(act_log_std)
    μ = actor(state)[1]

    # sample an action from a normal distribution with mean μ and standard deviation σ
    d = Normal(μ, σ)
    action = rand(d)

    # calculate the log probability of this action
    v = σ^2
    log_scale = log(σ)
    log_prob = -((action - μ)^2) / (2 * v) - log_scale - log(sqrt(2 * π))

    return action, log_prob
end

function run_episode(actor, act_log_std, critic, max_steps)
    states = Array{Float32}(undef, state_size, max_steps)
    actions = Array{Float32}(undef, max_steps)
    log_probs = Array{Float32}(undef, max_steps)
    rewards = Array{Float32}(undef, max_steps + 1)
    values = Array{Float32}(undef, max_steps + 1)
    state = env_reset()
    n_steps = max_steps
    for i = 1:max_steps
        # add state to buffer
        states[:,i] = state[:]

        # get action, log prob of action and value estimate
        action, log_prob = act(actor, act_log_std, state)
        actions[i] = action
        log_probs[i] = log_prob
        values[i] = critic(state)[1]

        # update the environment
        reward, done = env_step(state, action)

        # add reward to buffer
        rewards[i] = reward

        # check for episode ending
        if done
            n_steps = i
            break
        end
    end

    # set the final value to 0
    values[n_steps + 1] = 0
    return view(states, :, 1:n_steps), view(actions, 1:n_steps), view(log_probs, 1:n_steps), view(rewards, 1:n_steps), view(values, 1:n_steps + 1)
end

function discount_cumsum(values, discount_array)
    sz = size(values)[1]
    res = similar(values)
    for i = 1:sz
        res[i] = sum(view(values, i:sz) .* view(discount_array, 1:sz-i+1))
    end
    return res
end

function policy_loss(actor, act_log_std, states, actions, adv_est)
    μ = actor(states)
    σ = exp(act_log_std)  
    v = σ^2
    log_scale = log(σ)
    log_prob = -((actions .- μ').^2) ./ (2 * v) .- log_scale .- log(sqrt(2 * π))
    loss = -mean(log_prob .* adv_est)
    return loss
end

function value_loss(critic, states, rewards2go)
    values = critic(states)
    loss = (values' .- rewards2go) .^ 2
    return mean(loss)
end

function train(n_epochs, batch_size)

    # set hyper parameters
    γ = 0.99
    λ = 0.97

    max_steps = 200
    gamma_arr = Array{Float32}(undef, max_steps)
    gamma_lam_arr = Array{Float32}(undef, max_steps)
    for i = 1:max_steps
        gamma_arr[i] = γ ^ (i-1)
        gamma_lam_arr[i] = (γ * λ) ^ (i-1)
    end

    # create the policy network and optimiser
    actor = Chain(
        Dense(state_size, 64, tanh),
        Dense(64, 64, tanh),
        Dense(64, 1)
    )
    act_log_std = -0.5
    act_optimiser = ADAM(3e-4)
    act_params = params(actor, act_log_std)

    # create the value network and optimiser
    critic = Chain(
        Dense(state_size, 64, tanh),
        Dense(64, 64, tanh),
        Dense(64, 1)
    )
    crt_optimiser = ADAM(3e-4)
    crt_params = params(critic)

    # run n_epochs updates
    res = zeros(n_epochs)
    for i = 1:n_epochs
        st = now()

        # run a batch of episodes
        n = 0
        states_buf = Array{Float32}(undef, state_size, 0)
        actions_buf = Array{Float32}(undef, 0)
        log_probs_buf = Array{Float32}(undef, 0)
        r2g_buf = Array{Float32}(undef, 0)
        adv_buf = Array{Float32}(undef, 0)
        sr = 0.0
        ne = 0.0
        while n < batch_size

            # run an episode
            states, actions, log_probs, rewards, values = run_episode(actor, act_log_std, critic, max_steps)
            sr += sum(rewards)
            ne += 1

            # calculate the rewards to go
            r2g = discount_cumsum(rewards, gamma_arr)

            # calculate the advantage estimates
            sz = size(values)[1]
            δ = view(rewards, 1:sz-1) + γ * view(values, 2:sz) - view(values, 1:sz-1)
            adv_est = discount_cumsum(δ, gamma_lam_arr)

            # update the buffers
            states_buf = cat(states_buf, states, dims=2)
            actions_buf = cat(actions_buf, actions, dims=1)
            log_probs_buf = cat(log_probs_buf, log_probs, dims=1)
            r2g_buf = cat(r2g_buf, r2g, dims=1)
            adv_buf = cat(adv_buf, adv_est, dims=1)
            n = size(states_buf)[end]
            
        end
        sr /= ne
        println(i, ", ave rewards per episode: ", sr)
        open("training_rewards.csv", "a") do io
            write(io, string(sr, "\n"))
        end

        # normalise the advantage estimates
        μ = mean(adv_buf)
        σ = std(adv_buf)
        adv_buf = (adv_buf .- μ) ./ σ

        # update the policy network
        p_grad = gradient(act_params) do 
            p_loss = policy_loss(actor, act_log_std, states_buf, actions_buf, adv_buf)
            return p_loss
        end
        update!(act_optimiser, act_params, p_grad)

        # update the value network
        v_grad = gradient(crt_params) do
            v_loss = value_loss(critic, states_buf, r2g_buf)
            return v_loss
        end
        update!(crt_optimiser, crt_params, v_grad)

        println("step time: ", now() - st)
    end
    return res
end

ini = now()
batch_size = 1000
n_epochs = 100
res = train(n_epochs, batch_size)
println("total time: ", now() - ini)
# # plot results
# x = 1:n_epochs
# display(plot(x, res, label="rewards per episode"))
# readline()
