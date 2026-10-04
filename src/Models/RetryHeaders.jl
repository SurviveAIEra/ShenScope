const MODEL_HTTP_MONTHS = Dict(name=>index for (index,name) in enumerate(
    ("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec")))
const MODEL_HTTP_WEEKDAYS = ("Mon","Tue","Wed","Thu","Fri","Sat","Sun")

function model_retry_numeric_delay(raw::AbstractString;milliseconds=false)
    value = strip(raw)
    ncodeunits(value) <= 128 || return (nothing,:too_large)
    occursin(r"^[0-9]+(?:\.[0-9]+)?$",value) || return (nothing,:invalid)
    parsed = tryparse(Float64,value)
    parsed !== nothing && isfinite(parsed) || return (nothing,:too_large)
    delay = milliseconds ? parsed/1000 : parsed
    delay,:valid
end

function model_retry_http_date(raw::AbstractString;wall_time=time())
    isfinite(wall_time) || throw(ArgumentError("HTTP date reference time must be finite"))
    ncodeunits(raw) <= 128 && !any(iscntrl,raw) || return (nothing,:invalid)
    matched = match(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$",strip(raw))
    matched === nothing && return (nothing,:invalid)
    date = try
        DateTime(parse(Int,matched[4]),MODEL_HTTP_MONTHS[matched[3]],parse(Int,matched[2]),
            parse(Int,matched[5]),parse(Int,matched[6]),parse(Int,matched[7]))
    catch
        return (nothing,:invalid)
    end
    MODEL_HTTP_WEEKDAYS[dayofweek(date)] == matched[1] || return (nothing,:invalid)
    max(0.0,datetime2unix(date)-wall_time),:valid
end

function model_retry_advice(response;monotonic_time=model_monotonic_time(),wall_time=time())
    isfinite(monotonic_time) || throw(ArgumentError("Retry reference clock must be finite"))
    retry_header = HTTP.header(response,"x-should-retry","")
    server_retry = retry_header == "true" ? true : retry_header == "false" ? false : nothing
    millisecond_header = HTTP.header(response,"retry-after-ms",nothing)
    delay,status = millisecond_header === nothing ? (nothing,:absent) : model_retry_numeric_delay(millisecond_header;milliseconds=true)
    if status in (:absent,:invalid)
        header = HTTP.header(response,"Retry-After",nothing)
        if header !== nothing
            numeric,numeric_status = model_retry_numeric_delay(header)
            delay,status = numeric_status == :invalid ? model_retry_http_date(header;wall_time) : (numeric,numeric_status)
        end
    end
    ModelRetryAdvice(delay,Float64(monotonic_time),server_retry,status)
end

function model_response_failure(response,body=nothing;advice=model_retry_advice(response))
    status = Int(response.status)
    error = http_error(status,body)
    # An explicit server retry signal can make a model-request conflict
    # transient; it cannot reclassify authentication, context or bad input.
    if status == 409 && advice.server_retry === true
        error = ShenScopeError(:server,"Model endpoint returned HTTP 409",true)
    elseif status == 529
        error = ShenScopeError(:server,"Model endpoint returned HTTP 529",true)
    end
    ModelAttemptFailure(error,advice,status)
end

function model_attempt_failure(cause)
    for _ in 1:16
        cause isa HTTP.Exceptions.RequestError || break
        cause = cause.error
    end
    cause isa ModelAttemptFailure && return cause
    error = cause isa ShenScopeError ? cause : ShenScopeError(:transport,"Model transport failed",true)
    ModelAttemptFailure(error,ModelRetryAdvice(),nothing)
end
