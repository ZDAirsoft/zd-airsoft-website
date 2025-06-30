// Load interactivity after DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  console.log("Z&D Airsoft loaded successfully!");

  // Carousel Setup
  let currentIndex = 0;
  let slides = document.querySelectorAll('.carousel-slide');
  let playing = true;
  const caption = document.getElementById('carouselCaption');
  const btn = document.getElementById('playPauseBtn');

  if (slides.length > 0) {
    showSlide(currentIndex);
    var interval = setInterval(nextSlide, 3000);

    slides.forEach(slide => {
      slide.addEventListener('click', togglePlay);
    });
  }

  function showSlide(index) {
    slides.forEach((slide, i) => {
      slide.style.display = i === index ? 'block' : 'none';
    });
    caption.textContent = slides[index]?.alt || '';
  }

  function nextSlide() {
    currentIndex = (currentIndex + 1) % slides.length;
    showSlide(currentIndex);
  }

  function prevSlide() {
    currentIndex = (currentIndex - 1 + slides.length) % slides.length;
    showSlide(currentIndex);
  }

  function togglePlay() {
    if (playing) {
      clearInterval(interval);
      btn.textContent = '▶️';
    } else {
      interval = setInterval(nextSlide, 3000);
      btn.textContent = '⏸️';
    }
    playing = !playing;
  }

  // Navigation Menu toggle — ensure CSS expects 'active', not 'open'
  document.querySelector('.menu-toggle').addEventListener('click', () => {
    document.getElementById('navMenu').classList.toggle('active');
  });

  // Smooth Back-to-top button
  const topBtn = document.getElementById("backToTop");
  window.addEventListener('scroll', () => {
    if (window.scrollY > 300) topBtn.style.display = "block";
    else topBtn.style.display = "none";
  });
  topBtn.addEventListener("click", () => {
    window.scrollTo({ top: 0, behavior: "smooth" });
  });

  // Facebook toggle
  document.getElementById("fbToggle").addEventListener("click", () => {
    document.getElementById("fbFeedPanel").classList.toggle("visible");
  });

}); // DOMContentLoaded end
