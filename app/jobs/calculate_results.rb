class CalculateResults
  include SuckerPunch::Job
  
  def perform(calc_run)
    Rails.logger.info("*********** Calc run ***************")
    @calc_run_id = calc_run.id
    calc_results("Sprint")
    calc_results("Yellow")
    calc_results("Orange")
    calc_results("Green")
    calc_results("Brown")
    calc_results("Red")
    normalize_scores
    create_power_rankings
    Rails.logger.info("--> calc run complete <---")
  end
  
  private
  
  def calc_results(course)
    #Process course until average calculation delta drops below 0.5 or we exceed 15 passes
    Rails.logger.info("Calculate results:  Calc id: #{@calc_run_id} - #{course}")
    init_globals(course)
    delta = 99.5 # init delta to high value.
    pass  = 0
    while (delta > 0.5) do
      pass += 1
      delta = calc_race_gv(course)
      if (pass > 20)
        break
      end
      Rails.logger.info("--> #{course} Pass: #{pass}, delta: #{delta}")
    end
    # final run to update database
    @update_db = true # update runners
    Rails.logger.info("--> Update database <--")
    calc_race_gv(course)
  end

  # initialize global calculation values
  def init_globals(course)
    # clear cache
    @c_runner_gv = nil
    @c_runner_gv = LruRedux::Cache.new(2000)
    @course_time = nil
    @update_db   = false
    @course      = course
  end

  # calculate race / course garliness factor
  def calc_race_gv(course)
    # Rails.logger.info("Process course #{course}")
    total_delta = 0.0
    meet_cnt    = 0
    meets       = get_meets
    meets.each do |meet|
      delta = process_course(meet,course)
      next if delta == nil
      meet_cnt += 1
      total_delta += delta
      calc_runners_gv(course)
    end
    total_delta / meet_cnt
  end
  
  #calc run is based on meets for the last year
  def get_meets
    Meet.where("date > ?", Date.today - 1.year)
  end

  # process course results
  def process_course(meet,course)
    return nil if Result.where(meet: meet.id, course: course).count < 3
    process_course_results(meet.id,course).abs
  end
  

  # If there are three of each gender, calcs will be by gender.
  # def get_course_by_gender(meet,course)
  #   @female_runners = Result.where(meet: meet.id, course: course, gender: 'F', classifier: '0').count
  #   @female_runners >= 2 &&
  #   Result.where(meet: meet.id, course: course, gender: 'M', classifier: '0').count >= 2
  # end
  
  def process_course_results(meet_id,course)
    runner_entry = Struct.new(:runner_id, :runner_time, :result_id)
    runner_times = []
    score_list   = []
    results = get_course_results(meet_id,course)
    results.each do |result|
      # if valid result
      if result.classifier == 0
        runner_gv    = get_runner_gv(result,course,meet_id)
        score_list   << (result.float_time * runner_gv)
        runner_times << runner_entry.new(result.runner_id, result.float_time, result.id)
      end
    end
    # return 0 if score_list.size < 3
    course_cgv = get_harmonic_mean(score_list)
    # puts "#course cgv #{course_cgv}"
    delta = update_meet_course_results(meet_id, results, course_cgv, course, runner_times)
  end
  
  # Update cource resutls based on course calculated garliness valaue
  def update_meet_course_results(meet_id, results, course_cgv, course, runner_times)
    first_time = true
    delta      = 1.0

    runner_times.each do |runner|
      time  = runner.runner_time
      runner_score = course_cgv/time
      calc_result = CalcResult.where(calc_run_id: @calc_run_id,
                                     meet_id: meet_id,
                                     result_id: runner.result_id,
                                     runner_id: runner.runner_id,
                                     course: course).first
      if calc_result == nil
        calc_result = CalcResult.new(calc_run_id: @calc_run_id,
                                     meet_id: meet_id,
                                     result_id: runner.result_id,
                                     runner_id: runner.runner_id,
                                     course: course,
                                     float_time: time,
                                     score: runner_score,
                                     course_cgv: course_cgv,)
      else
        if first_time
          delta = ((course_cgv - calc_result.course_cgv) / calc_result.course_cgv) * 100
          first_time = false
        end
        calc_result.course_cgv = course_cgv
        calc_result.score      = runner_score
      end
      calc_result.save
    end
    delta
  end
  
  # get meet/course resutls
  def get_course_results(meet_id,course)
    results = Result.where(meet: meet_id, course: course, classifier: '0').order(:float_time)
    @course_time = get_course_time(results) #need to cache this
    results
  end
  
  # get runner's initial gnarliness value (GV)
  def get_runner_gv(result,course,meet_id)
    return get_initial_gv(result) if @c_runner_gv[result.runner_id].nil?
    @c_runner_gv[result.runner_id][:cgv]
  end
  
  # runners initial GV is on the course time. Course time = 100,
  def get_initial_gv(result)
    gv = (@course_time / result.float_time) * 100
    @c_runner_gv[result.runner_id] = {cgv: gv, score: gv, races: 1}
    gv
  end
  
  # course time is based on the harmonic mean of the top three times for the course.
  def get_course_time(results)
    list = []
    results.take(3).each do |r|
      list << r.float_time
    end
    get_harmonic_mean(list)
  end
  
  # calculate runners garliness factor
  def calc_runners_gv(course)
    current_runner_id   = nil
    score_list          = []
    races               = 0
    CalcResult.where(calc_run_id: @calc_run_id, course: course)
              .order(:runner_id, score: :desc)
              .select("id, runner_id, score").each do |r|
      if current_runner_id == nil
        current_runner_id = r.runner_id
      elsif current_runner_id != r.runner_id
        update_runners_gv(score_list, current_runner_id, races)
        score_list = []
        current_runner_id = r.runner_id
        races = 0
      end
      races += 1
      if r.score > 0
        score_list << r.score
      end
    end
    # process last runner
    update_runners_gv(score_list, current_runner_id, races)
  end

  # calculate and update the runners GV
  def update_runners_gv(score_list, runner_id, races)
    ranking_score = calc_modified_average(score_list)
    cgv_score = score_list.reduce(:+).to_f / score_list.size
    if @update_db == false
      @c_runner_gv[runner_id] = {cgv: cgv_score, score: ranking_score, races: races}
    else
      RunnerGv.find_or_initialize_by(runner_id: runner_id,
                                     calc_run_id: @calc_run_id,
                                     course: @course)
              .update_attributes!(cgv: cgv_score, score: ranking_score, races: races)
    end
  end
  
  # for every 2 races past 4, the runner drops there lowest score.
  def calc_modified_average(score_list)
    sum = 0;
    calc_size = score_list.size
    calc_size = (4 + (calc_size-4)/2) if (calc_size > 5)

    calc_size.times do |score|
      sum += score_list[score]
    end
    (sum / calc_size)
  end

  # calculate hamonic mean for list of values
  def get_harmonic_mean(score_list)
    sum = 0
    score_list.each  do | score |
      sum += (1.0/score)
    end
    mean = score_list.size / sum
  end

  # normalize scores for high school power rankings
  # the average of the top 10% of results (min of 2) for
  # each class/gender will represent a score of 100
  def normalize_scores
    COURSES.each do |course|
      ['M','F'].each do |gender|
        # do not include male / brown course results
        next if course == 'Brown' && gender == 'M'
        normalize_course_scores(course, gender)
      end
    end
  end

  def normalize_course_scores(course, gender)
    Rails.logger.info("--> normalize results #{course}, #{gender}")
    results = RunnerGv.joins(:runner)
                .where(calc_run_id: @calc_run_id, course: course, 'runners.sex': gender)
                  .where("runners.club_description like '% HS'")
                    .where('races > 1')
                      .order(score: :desc)
    count = results.count
    return if count == 0
    normalize_factor = 100 / get_normalized_score(results, count)
    set_normalized_value(results, normalize_factor)
  end
  
  def set_normalized_value(results, normalize_factor)
    results.each do |r|
      r.normalized_score = r.score * normalize_factor
      r.save
    end
  end
  
  def get_normalized_score(results, count)
    score_list = []
    limit = (count * 0.10).ceil
    limit = 2 if limit < 2
    top_results = results.limit(limit)
    top_results.each do |r|
      score_list << r.score
    end
    score_list.inject { |sum, el| sum + el}.to_f / score_list.size
  end
  
  def create_power_rankings
    Rails.logger.info("--> create power rankings")
    @exclude = []
    create_power_ranking_by_class("Varsity", ['Red','Green','Brown'])
    create_power_ranking_by_class("Junior Varsity", ['Orange'])
    create_power_ranking_by_class("Intermediate", ['Yellow'])
  end
  
  def create_power_ranking_by_class(ranking_class, courses)
    Rails.logger.info("----> #{ranking_class}")
    schools = RunnerGv.joins(:runner)
               .where(calc_run_id: @calc_run_id, course: courses)
                 .where("runners.club_description like '% HS'")
                   .where("races > 1")
                     .uniq.pluck('runners.club_description')
    schools.each do |school|
      calc_schools_ranking(school, courses, ranking_class)
    end
  end
  
  def calc_schools_ranking(school, courses, ranking_class)
    puts "exclude #{@exclude}"
    results = RunnerGv.joins(:runner)
                .where(calc_run_id: @calc_run_id, course: courses, 'runners.club_description': school)
                  .where('races > 1')
                    .where.not(normalized_score: nil, runner_id: @exclude)
                      .order(normalized_score: :desc)
                        .limit(5)
    
    # results.where.not(runner_id: @exclude)
    return if results.count == 0
    team_score = 0
    pw = PowerRanking.new(calc_run_id: @calc_run_id, school: school, ranking_class: ranking_class)
    pw.save
    results.each do |r|
      team_score += r.normalized_score
      RankingAssignment.new(power_ranking_id: pw.id, runner_id: r.runner_id, runner_gv_id: r.id).save
      @exclude << r.runner_id
    end
    if team_score > 0
      pw.total_score = team_score
      pw.save
      Rails.logger.info("------> #{school}")
      Rails.logger.info("-------->team score #{pw.total_score}")
    end
  end
  
end