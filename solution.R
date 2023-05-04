# install.packages(c("data.table", "ggplot2", "readxl", "rlist"))

library(readxl)
library(data.table)
library('rlist')
library(ggplot2)

base_folder <- "/home/cafebazar/covid-deaths/" # change this:)
iranprovs_mortality_monthly_file_location <- paste0(base_folder,"iranprovs_mortality_monthly.csv")
provinces_death_export_file_location <- paste0(base_folder, "output/provinces-death.csv")
province_score_export_file_location <- paste0(base_folder, "output/provinces-scores.csv")


dt <- data.table(read.csv( iranprovs_mortality_monthly_file_location))

# adding seasons
seasons <- c("spring", "summer", "fall", "winter")
dt[, season := seasons[((m - 1) %/% 3) + 1]]

# adding month in season
dt[, month_in_season := ((m - 1) %% 3) + 1]

# adding time column
dt[, time := y + (m-1)/12]

# adding category columns (using dummy vars)
category_columns <- NULL

add_and_encode_category <- function(datatable, category_name) {
  categories <- unique(datatable[,get(category_name)])
  for(i in 2:length(categories)){
    column_name <- paste0(category_name, i)
    dt[, (column_name) := (get(category_name) == categories[i])]
    category_columns <<- c(category_columns, column_name)
  }
  datatable
}

dt <- add_and_encode_category(dt, "sex")
# split into pre covid and post covid



provinces <- unique(dt[, prov])
age_groups <- unique(dt[, age_group])

age_group_1 <- age_groups[1:4]
age_group_2 <- age_groups[5:7]
age_group_3 <- age_groups[8:17]
age_group_4 <- age_groups[18:21]

get_age_group <<- function (ag) {
  group <- 0
  for(j in 1:4) {
    if( ag %in% get(paste0("age_group_", as.character(j)))) {
      group <- j
      break
    }
  }
  group
}

#
get_age_group_index <- function (ag, group) {
  which(ag == get(paste0("age_group_", as.character(group))))
}

dt[, age_group_modified :=  mapply(get_age_group, age_group)]

dt[, age_group_index :=  mapply(get_age_group_index, age_group, age_group_modified)]


MODEL_P_VALUE_THRESHOLD <<- 0.05
AGGREGATE_THRESHOLD <<- 50
number_of_regressions <<- 0
number_of_intercepts <<- 0
get_death_by_model <<- function (post_covid, model) {

  number_of_regressions <<- number_of_regressions + 1

  prediction <- predict(model, newdata = post_covid)
  real_deaths <- post_covid$n
  k <- length(model$coefficients)-1

  SSE <- sum(model$residuals^2)

  n <- length(model$residuals)

  rse <- sqrt(SSE/(n-(1+k)))

  res <- 0
  deaths <- NULL
  predicted_death <- NULL
  excess_death <- NULL
  for (i in seq_along(prediction)) {
    deaths <- c(deaths, real_deaths[i])
    predicted_death <- c(predicted_death, prediction[i])
    if (real_deaths[i] > prediction[i] + 2 * rse){
      res <- res + (real_deaths[i] - prediction[i])
      excess_death <- c(excess_death, (real_deaths[i] - prediction[i]))
    } else {
      excess_death <- c(excess_death, 0)
    }
  }

  normalized_deaths <- data.table(
    "time" = post_covid$time,
    "deaths" = deaths,
    "predicted_deaths" = predicted_death,
    "excess_death" = excess_death
  )


  list(res, normalized_deaths)
}


get_death_by_intercept <<- function (pre_covid, post_covid) {

  number_of_intercepts <<- number_of_intercepts + 1

  mean_deaths <-mean(pre_covid[, .(n = sum(n)),by= time]$n)
  sd_death <- sd(pre_covid[, .(n = sum(n)),by= time]$n)
  post_covid <- post_covid[, .(n = sum(n)), by= time]
  post_covid_time <- post_covid$time
  post_covid_deaths <- post_covid$n

  res <- 0
  deaths <- NULL
  predicted_death <- NULL
  excess_death <- NULL
  for(i in seq_along(post_covid_deaths)) {
    deaths <- c(deaths, post_covid_deaths[i] )
    predicted_death <- c(predicted_death, mean_deaths)
    if(post_covid_deaths[i] > mean_deaths + 2 * sd_death) {
      res <- res + post_covid_deaths[i] - mean_deaths
      excess_death <- c(excess_death, (post_covid_deaths[i] - mean_deaths))
    } else {
      excess_death <- c(excess_death, 0)
    }
  }

  normalized_deaths <- data.table(
    "time" = post_covid_time,
    "deaths" = deaths,
    "predicted_deaths" = predicted_death,
    "excess_death" = excess_death
  )

  list(res, normalized_deaths)
}

get_all_subsets <<- function (set) {
  all_subsets <- list()
  for(mask in 0:(2^(length(set))-1)) {
    tmp <- mask
    subset <- NULL
    for(j in seq_along(set)) {
      if(tmp %% 2 == 1) {
        subset <- c(subset, set[j])
      }
      tmp <- tmp %/% 2
    }
    all_subsets <- list.append(all_subsets, subset)
  }
  all_subsets
}


find_best_model <<- function(pre_covid, features) {
  best_r_squared <- -1
  best_model <- NULL
  best_featues <- NULL
  all_feature_subsets <-get_all_subsets(features)
  for(selected_features in all_feature_subsets) {
    if (length(selected_features) == 0) {
      next
    }
    data <- pre_covid[,  .(n = sum(n)), by=mget(c(selected_features, "time"))]
    if (mean(data$n) < AGGREGATE_THRESHOLD) {
      next
    }
    if (nrow(data) <= length(selected_features) + 2){
      next
    }
    model <- lm(as.formula(paste0("n ~ ",paste(c(selected_features, "time"), collapse = "+", sep="+"))), data)
    model_summary <- summary(model)
    if (max(model_summary$coefficients[, 4]) < MODEL_P_VALUE_THRESHOLD) {
      if(model_summary$adj.r.squared > best_r_squared) {
        best_r_squared <- model_summary$adj.r.squared
        best_model <- model
        best_featues <- selected_features
      }
    }
  }
  list(best_model, best_r_squared, best_featues)
}



fit_pre_covid <<- function(pre_covid, features) {
  tmp <- find_best_model(pre_covid, features)
  r_squared <- tmp[[2]]
  best_model <- tmp[[1]]
  if(is.null(best_model)) {
    return(0)
  }
  r_squared
}

get_aggragate_datatable <<- function(datatable, aggragator) {
  tmp_list <- list(datatable)
  for(aggragate in aggragator) {
    values <- unique(datatable[, get(aggragate),])
    tmp_list2 <- list()
    for(tmp in tmp_list) {
      for(value in values) {
        tmp_list2 <- list.append(tmp_list2, tmp[ get(aggragate) == value, ,])
      }
    }
    tmp_list <- tmp_list2
  }
  tmp_list
}

get_covid_deaths <<- function(pre_covid, post_covid, features, aggragators) {
  aggragators_subset <- get_all_subsets(aggragators)
  best_aggragator <- NULL
  best_mean_r_squared <- -1
  for (aggragator in aggragators_subset) {
    tmp_pre_covid_list <- get_aggragate_datatable(pre_covid, aggragator)
    tmp_post_covid_list <- get_aggragate_datatable(post_covid, aggragator)
    mean_r_squared <- 0
    for (i in seq_along(tmp_pre_covid_list)) {
      tmp <- fit_pre_covid(tmp_pre_covid_list[[i]], features)
      mean_r_squared <- tmp + mean_r_squared
    }
    mean_r_squared <- mean_r_squared / length(tmp_post_covid_list)
    if(mean_r_squared > best_mean_r_squared) {
      best_mean_r_squared <- mean_r_squared
      best_aggragator <- aggragator
    }
  }
  pre_covid_list <- get_aggragate_datatable(pre_covid, best_aggragator)
  post_covid_list <- get_aggragate_datatable(post_covid, best_aggragator)

  normalized_death <- data.table(
    "time" = double(),
    "deaths" = double(),
    "predicted_deaths" = double(),
    "excess_death" = double()
  )
  deaths <- 0
  for(i in seq_along(pre_covid_list)) {
    pre_covid_tmp <- pre_covid_list[[i]]
    post_covid_tmp <- post_covid_list[[i]]
    tmp <- find_best_model(pre_covid_tmp, features)
    tmp_model <- tmp[[1]]
    tmp_features <- tmp[[3]]
    if (is.null(tmp_model)) {
      tmp_res <- get_death_by_intercept(pre_covid_tmp, post_covid_tmp)
    } else {
      tmp_res <- get_death_by_model(post_covid_tmp[, .(n = sum(n)), by=mget(c(tmp_features, "time"))], tmp_model)
    }
    deaths <- deaths + tmp_res[[1]]
    normalized_death <- rbindlist(list(normalized_death, tmp_res[[2]]))
  }
  list(deaths, normalized_death)
}

ans <<- 0


normalized_death <- data.table(
  "time" = double(),
  "deaths" = double(),
  "predicted_deaths" = double(),
  "excess_death" = double(),
  "province" = character()
)

for(prov_name in provinces) {
  normalized_death_province <- data.table(
    "time" = double(),
    "deaths" = double(),
    "predicted_deaths" = double(),
    "excess_death" = double()
  )
  for(s in seasons) {
    pre_covid <- dt[time > (1394) & time < (1398 + 10 / 12) & prov == prov_name & season == s]
    post_covid <- dt[time >= (1398 + 10 / 12) & prov == prov_name & season == s]

    tmp <-  get_covid_deaths(pre_covid, post_covid, c("sex2", "age_group_index"),
                                       c("age_group_modified", "month_in_season"))
    tmp_death <- tmp[[1]]
    normalized_death_province <- rbindlist(list(normalized_death_province, tmp[[2]]))
    ans <<- ans + tmp_death
  }
  normalized_death <- rbindlist(list(normalized_death, normalized_death_province[, .( deaths = sum(deaths), predicted_deaths = sum(predicted_deaths), excess_death = sum(excess_death),province = prov_name), by=time]))
}


total_excess_death <<- ans

normalized_death[, normalized_deaths:= excess_death / predicted_deaths]




ggplot(normalized_death, aes(x = time, y = province, fill = normalized_deaths)) +
  geom_tile(color = "black") +
  scale_fill_gradient(low = "white", high = "red")

ggsave(paste0(base_folder, "output/heatmap-provinces-by-time.png"))

death_by_provinces <- normalized_death[, .(excess_death = sum(excess_death), normalized_death= sum(excess_death) / sum(predicted_deaths), predicted_deaths = sum(predicted_deaths)), by=province]

write.csv(death_by_provinces, provinces_death_export_file_location)

pre_covid <- dt[time > (1394) & time < (1398 + 10 / 12), , ]


old_age_group <- age_groups[11:17]

old_people_death_province <- pre_covid[age_group %in% old_age_group,
  .(old_people_death_before_covid = sum(n)),
  by=.(prov)]

total_death_province_bf_covid <- pre_covid[,
                                           .(before_covid_death = sum(n)),
                                           by=.(prov)]

province_bf_covid_stats <-  merge(old_people_death_province, total_death_province_bf_covid, by='prov')

colnames(province_bf_covid_stats)[colnames(province_bf_covid_stats) == "prov"] <- "province"
excess_death_province_old_people <- merge(province_bf_covid_stats, death_by_provinces, by='province')


model <- lm("excess_death~old_people_death_before_covid", data=excess_death_province_old_people)


model_summary <- summary(model)

excess_death_province_old_people$residuals <- model_summary$residuals

excess_death_province_old_people[, score := residuals / predicted_deaths]

ggplot(excess_death_province_old_people, aes(x = 1, y = province, fill = score)) +
  geom_tile() +
  scale_fill_gradient(low = "green", high = "red")

ggsave(paste0(base_folder, "output/provinces-performances.png"))

setorder(excess_death_province_old_people, cols='score')

write.csv(excess_death_province_old_people[, .(province, score)], province_score_export_file_location)

print(paste("total excess death is:", as.character(total_excess_death)))